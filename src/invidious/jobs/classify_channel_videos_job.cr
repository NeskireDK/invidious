# Labels subscription feed rows with their content kind (ArikTube extension).
#
# A separate job rather than an edit to `fetch_channel`: this branch tracks
# upstream release tags, and that function is one upstream changes most. `kind`
# is also absent from the insert's `ON CONFLICT DO UPDATE` set, so a channel
# refresh cannot overwrite a label.
#
# Tracks by MERGING a release tag in, not by rebasing. `arik` is the branch CI
# publishes :latest from, so rewriting its commits would mean force-pushing a
# deploy branch.
#
# Two passes, because a 15-entry feed window cannot answer for the whole table:
# the Shorts and live windows per channel, then a capped `/shorts/<id>` probe
# for every row the windows cannot settle — both the ones older than the window
# and the ones too fresh to eliminate (see SHORTS_FEED_LAG). The probe only
# answers short/not-short, so a stream VOD in the tail is labelled `video`.
class Invidious::Jobs::ClassifyChannelVideosJob < Invidious::Jobs::BaseJob
  private getter db : DB::Database

  INTERVAL          = 15.minutes
  CHANNELS_PER_TICK = 25
  PROBES_PER_TICK   = 60
  REQUEST_DELAY     = 500.milliseconds

  # YouTube publishes an upload to the UUSH Shorts playlist feed later than a
  # channel refresh sees it, so a fresh row's absence from the Shorts window is
  # not evidence it is long-form. Measured on 2026-09-01: three Shorts were
  # labelled `video` within minutes of publication and were listed in the
  # Shorts feed hours later. Elimination waits this long; the probe answers
  # sooner and correctly.
  SHORTS_FEED_LAG = 24.hours

  # `oldest` nil means the window carried nothing, which is a valid answer —
  # no uploads of that kind, so YouTube 404s the playlist. A window that could
  # not be *read* is a nil window.
  alias Window = {ids: Array(String), oldest: Time?}

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

        changed = apply_window(ucid, shorts, lives)
        mark_feeds_stale([ucid]) if changed > 0
        labelled += changed
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: #{ucid} : #{ex.message}")
      end
    end

    labelled
  end

  private def apply_window(ucid : String, shorts : Window, lives : Window) : Int32
    labelled = write_kind(shorts[:ids], Invidious::ArikFeedKinds::KIND_SHORT)
    labelled += write_kind(lives[:ids], Invidious::ArikFeedKinds::KIND_LIVE)

    settled = Time.utc - SHORTS_FEED_LAG

    if shorts[:ids].empty? && lives[:ids].empty?
      # Neither kind exists for this channel, so elimination holds for its
      # whole history and the tail pass never has to see it.
      request = <<-SQL
        UPDATE channel_videos SET kind = $1
        WHERE ucid = $2 AND kind IS NULL AND published < $3
      SQL

      return labelled + PG_DB.exec(
        request, Invidious::ArikFeedKinds::KIND_VIDEO, ucid, settled
      ).rows_affected.to_i32
    end

    # Elimination is sound only as far back as both windows saw. Past that a
    # row's absence proves nothing, so it is left to the tail pass.
    horizon = [shorts[:oldest], lives[:oldest]].compact.max?
    return labelled if horizon.nil?

    request = <<-SQL
      UPDATE channel_videos SET kind = $1
      WHERE ucid = $2 AND kind IS NULL AND published >= $3 AND published < $4
    SQL

    labelled + PG_DB.exec(
      request, Invidious::ArikFeedKinds::KIND_VIDEO, ucid, horizon, settled
    ).rows_affected.to_i32
  end

  # A materialized view holds whatever `kind` said when it was last refreshed,
  # and RefreshFeedsJob only rebuilds a view whose owner is flagged. Without
  # this a corrected label never reaches the feed: the row keeps its old kind on
  # screen until an unrelated upload happens to flag that user.
  private def mark_feeds_stale(ucids : Array(String)) : Nil
    return if ucids.empty?

    request = <<-SQL
      UPDATE users SET feed_needs_update = true
      WHERE subscriptions && $1
    SQL

    PG_DB.exec(request, ucids)
  end

  private def channels_of(ids : Array(String)) : Array(String)
    return [] of String if ids.empty?

    request = <<-SQL
      SELECT DISTINCT ucid FROM channel_videos
      WHERE id = ANY($1) AND ucid IS NOT NULL
    SQL

    PG_DB.query_all(request, ids, as: String)
  end

  private def run_tail_pass : Int32
    labelled = 0
    written = [] of String

    pending_tail_videos.each do |id|
      begin
        kind = probe_kind(id)
        next if kind.nil?

        if write_kind([id], kind) > 0
          labelled += 1
          written << id
        end
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: probe #{id} : #{ex.message}")
      end
    end

    mark_feeds_stale(channels_of(written))
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
  #
  # The views themselves say what they were built for, so nothing here records
  # intent: a rebuild that failed leaves the marker it failed to write, and the
  # next tick tries again.
  private def reconcile_subscription_views : Nil
    return if views_current?

    rebuild_subscription_views
  end

  # False when any user's view is missing, or carries a feed-kinds marker other
  # than the one the configuration asks for.
  #
  # The marker is read off the view object. Checking that the view has a `kind`
  # attribute — which is what this used to do — proves nothing:
  # MATERIALIZED_VIEW_SQL is `SELECT cv.*`, so `kind` is a column of every
  # post-migration view whatever its predicate admits.
  #
  # pg_catalog, not information_schema: materialized views do not appear in
  # information_schema at all, so a check there silently passes for ever.
  # `left(..., 63)` mirrors the identifier truncation Postgres applies to
  # these names: "subscriptions_" plus 64 hex characters is 78.
  private def views_current? : Bool
    request = <<-SQL
      SELECT count(*) FROM users u
      WHERE NOT EXISTS (
        SELECT 1 FROM pg_class c
        WHERE c.relkind = 'm'
          AND c.relname = left('subscriptions_' || encode(sha256(u.email::bytea), 'hex'), 63)
          AND obj_description(c.oid, 'pg_class') = $1
      )
    SQL

    marker = Invidious::ArikFeedKinds.view_marker(CONFIG.feed_kinds)

    PG_DB.query_one(request, marker, as: Int64) == 0
  end

  # Builds each view beside the live one and swaps it in, so a CREATE that
  # fails leaves the user's feed alone. Dropping first cost both subscription
  # feeds on 2026-08-30, when the column the new definition referenced did not
  # exist yet.
  private def rebuild_subscription_views : Nil
    PG_DB.query_all("SELECT email FROM users", as: String).each do |email|
      view = "subscriptions_#{sha256(email)}"
      staging = "arik_staging_#{sha256(email)[0..31]}"

      begin
        PG_DB.exec("DROP MATERIALIZED VIEW IF EXISTS #{staging}")
        create_subscription_view(PG_DB, staging, email)

        PG_DB.transaction do |tx|
          tx.connection.exec("DROP MATERIALIZED VIEW IF EXISTS #{view}")
          tx.connection.exec("ALTER MATERIALIZED VIEW #{staging} RENAME TO #{view}")
        end

        LOGGER.info("ClassifyChannelVideosJob: rebuilt #{view} for kinds #{CONFIG.feed_kinds.join(",")}")
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: cannot rebuild #{view} (#{ex.message})")
        PG_DB.exec("DROP MATERIALIZED VIEW IF EXISTS #{staging}") rescue nil
      end
    end
  end
end
