# Labels subscription feed rows with their content kind (ArikTube extension).
#
# A separate job rather than an edit to `fetch_channel`: this branch rebases
# onto release tags, and that function is one upstream changes most. `kind` is
# also absent from the insert's `ON CONFLICT DO UPDATE` set, so a channel
# refresh cannot overwrite a label.
#
# Two passes, because a 15-entry feed window cannot answer for the whole table:
# the Shorts and live windows per channel, then a capped `/shorts/<id>` probe
# for rows older than those windows. The probe only answers short/not-short, so
# a stream VOD in the tail is labelled `video`.
class Invidious::Jobs::ClassifyChannelVideosJob < Invidious::Jobs::BaseJob
  private getter db : DB::Database

  INTERVAL          = 15.minutes
  CHANNELS_PER_TICK = 25
  PROBES_PER_TICK   = 60
  REQUEST_DELAY     = 500.milliseconds

  # `oldest` nil means the window carried nothing, which is a valid answer —
  # no uploads of that kind, so YouTube 404s the playlist. A window that could
  # not be *read* is a nil window.
  alias Window = {ids: Array(String), oldest: Time?}

  # Kinds the existing views were built for. In the database, not memory, so a
  # restart does no DDL.
  APPLIED_KEY = "feed_kinds_applied"

  def initialize(@db)
  end

  def begin
    loop do
      begin
        reconcile_subscription_views
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: cannot reconcile the subscription views (#{ex.message})")
      end

      begin
        classified = run_window_pass + run_tail_pass
        LOGGER.debug("ClassifyChannelVideosJob: classified #{classified} video(s)")
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: #{ex.message}")
      end

      sleep INTERVAL
    end
  end

  private def run_window_pass : Int32
    labelled = 0

    pending_channels.each do |ucid|
      begin
        shorts = feed_window(ucid, Invidious::ArikFeedKinds::KIND_SHORT)
        lives = feed_window(ucid, Invidious::ArikFeedKinds::KIND_LIVE)

        # Eliminating against a half-read pair would call a Short long-form.
        next if shorts.nil? || lives.nil?

        labelled += apply_window(ucid, shorts, lives)
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: #{ucid} : #{ex.message}")
      end
    end

    labelled
  end

  private def apply_window(ucid : String, shorts : Window, lives : Window) : Int32
    labelled = write_kind(shorts[:ids], Invidious::ArikFeedKinds::KIND_SHORT)
    labelled += write_kind(lives[:ids], Invidious::ArikFeedKinds::KIND_LIVE)

    if shorts[:ids].empty? && lives[:ids].empty?
      # Neither kind exists for this channel, so elimination holds for its
      # whole history and the tail pass never has to see it.
      request = <<-SQL
        UPDATE channel_videos SET kind = $1
        WHERE ucid = $2 AND kind IS NULL
      SQL

      return labelled + PG_DB.exec(
        request, Invidious::ArikFeedKinds::KIND_VIDEO, ucid
      ).rows_affected.to_i32
    end

    # Elimination is sound only as far back as both windows saw. Past that a
    # row's absence proves nothing, so it is left to the tail pass.
    horizon = [shorts[:oldest], lives[:oldest]].compact.max?
    return labelled if horizon.nil?

    request = <<-SQL
      UPDATE channel_videos SET kind = $1
      WHERE ucid = $2 AND kind IS NULL AND published >= $3
    SQL

    labelled + PG_DB.exec(
      request, Invidious::ArikFeedKinds::KIND_VIDEO, ucid, horizon
    ).rows_affected.to_i32
  end

  private def run_tail_pass : Int32
    labelled = 0

    pending_tail_videos.each do |id|
      begin
        kind = probe_kind(id)
        next if kind.nil?

        labelled += write_kind([id], kind)
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: probe #{id} : #{ex.message}")
      end
    end

    labelled
  end

  private def feed_window(ucid : String, kind : String) : Window?
    resource = Invidious::ArikFeedKinds.feed_resource(ucid, kind)
    return nil if resource.nil?

    sleep REQUEST_DELAY
    response = YT_POOL.client &.get(resource)

    return {ids: [] of String, oldest: nil} if response.status_code == 404
    return nil if response.status_code != 200

    namespaces = {
      "yt"      => "http://www.youtube.com/xml/schemas/2015",
      "default" => "http://www.w3.org/2005/Atom",
    }

    rss = XML.parse(response.body)
    ids = [] of String
    oldest = nil.as(Time?)

    rss.xpath_nodes("//default:feed/default:entry", namespaces).each do |entry|
      id = entry.xpath_node("yt:videoId", namespaces).try &.content
      next if id.nil?
      ids << id

      raw = entry.xpath_node("default:published", namespaces).try &.content
      next if raw.nil?

      published = Time.parse_rfc3339(raw) rescue nil
      next if published.nil?

      current = oldest
      oldest = published if current.nil? || published < current
    end

    {ids: ids, oldest: oldest}
  rescue ex
    LOGGER.trace("ClassifyChannelVideosJob: #{ucid} #{kind} feed : #{ex.message}")
    nil
  end

  private def probe_kind(id : String) : String?
    sleep REQUEST_DELAY
    response = YT_POOL.client &.head(Invidious::ArikFeedKinds.shorts_probe_resource(id))
    Invidious::ArikFeedKinds.kind_from_probe_status(response.status_code)
  rescue ex
    LOGGER.trace("ClassifyChannelVideosJob: probe #{id} : #{ex.message}")
    nil
  end

  private def pending_channels : Array(String)
    request = <<-SQL
      SELECT ucid FROM channel_videos
      WHERE kind IS NULL AND ucid IS NOT NULL
      GROUP BY ucid
      ORDER BY count(*) DESC
      LIMIT $1
    SQL

    PG_DB.query_all(request, CHANNELS_PER_TICK, as: String)
  end

  private def pending_tail_videos : Array(String)
    request = <<-SQL
      SELECT id FROM channel_videos
      WHERE kind IS NULL
      ORDER BY published DESC
      LIMIT $1
    SQL

    PG_DB.query_all(request, PROBES_PER_TICK, as: String)
  end

  # Only ever writes over NULL, so a later pass cannot undo the probe's answer.
  private def write_kind(ids : Array(String), kind : String) : Int32
    return 0 if ids.empty?

    request = <<-SQL
      UPDATE channel_videos SET kind = $1
      WHERE id = ANY($2) AND kind IS NULL
    SQL

    PG_DB.exec(request, kind, ids).rows_affected.to_i32
  end

  # A materialized view bakes the predicate in at CREATE time and `REFRESH`
  # re-runs that stored definition, so a view made before this feature keeps
  # serving every kind until it is recreated.
  private def reconcile_subscription_views : Nil
    wanted = CONFIG.feed_kinds.to_json
    return if Invidious::ArikSettings.fetch(APPLIED_KEY) == wanted && !stale_views?

    rebuild_subscription_views
    Invidious::ArikSettings.store(APPLIED_KEY, wanted)
  end

  # A view predating the `kind` column cannot carry the predicate whatever the
  # marker claims. This is what makes a restored backup heal itself.
  private def stale_views? : Bool
    request = <<-SQL
      SELECT count(*) FROM pg_matviews m
      WHERE m.matviewname LIKE 'subscriptions\\_%'
        AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns c
          WHERE c.table_name = m.matviewname AND c.column_name = 'kind'
        )
    SQL

    PG_DB.query_one(request, as: Int64) > 0
  end

  private def rebuild_subscription_views : Nil
    emails = PG_DB.query_all("SELECT email FROM users", as: String)

    emails.each do |email|
      view_name = "subscriptions_#{sha256(email)}"

      begin
        PG_DB.exec("DROP MATERIALIZED VIEW IF EXISTS #{view_name}")
        PG_DB.exec("CREATE MATERIALIZED VIEW #{view_name} AS #{MATERIALIZED_VIEW_SQL.call(email)}")
        LOGGER.info("ClassifyChannelVideosJob: rebuilt #{view_name} for kinds #{CONFIG.feed_kinds.join(",")}")
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: cannot rebuild #{view_name} (#{ex.message})")
      end
    end
  end
end
