# Labels subscription feed rows with their content kind (ArikTube extension).
#
# Deliberately a separate job rather than an edit to `fetch_channel`.
# `fetch_channel` is one of the functions upstream changes most, and the
# `arik` branch is rebased onto release tags — code placed there would be a
# conflict on every rebase. Upstream keeps inserting rows exactly as it does
# now; this job corrects them afterwards. `Database::ChannelVideos.insert`
# leaves `kind` out of its `ON CONFLICT DO UPDATE` set, so upstream's upsert
# physically cannot overwrite a label once written.
#
# Two passes, because one 15-entry feed window cannot answer for the whole
# table:
#
#   1. **Window pass** — for each channel that still owes answers, read its
#      Shorts and live-stream uploads feeds and label everything they carry.
#      Anything else that channel owes and that is *newer* than the point
#      both windows reached back to is long-form by elimination. Two requests
#      per channel, and it covers every new upload for ever after.
#
#   2. **Tail pass** — rows older than the windows, capped per tick. Probes
#      `/shorts/<id>`, where YouTube answers 200 for a Short and 303 for
#      everything else. Authoritative, but it only answers short/not-short,
#      so a stream VOD in the tail is labelled `video`. Accepted: the backlog
#      is finite and drains once, and a past stream reads as a normal video
#      in a feed anyway.
class Invidious::Jobs::ClassifyChannelVideosJob < Invidious::Jobs::BaseJob
  private getter db : DB::Database

  # How long a tick waits before the next one.
  INTERVAL = 15.minutes

  # Channels per tick. The window pass costs two requests each, and there is
  # no hurry: the steady state is a handful of channels per tick.
  CHANNELS_PER_TICK = 25

  # Probes per tick. 60 clears the ~530-row backlog of an established
  # instance in about two hours of ticks without ever looking like a scrape.
  PROBES_PER_TICK = 60

  # Pause between requests to YouTube, matching the politeness of the rest of
  # the instance's channel traffic.
  REQUEST_DELAY = 500.milliseconds

  # One feed window: the IDs it carried, and the publish date of its oldest
  # entry. `oldest` is nil for a window that carried nothing, which is a
  # valid answer — a channel that has never posted a Short has no Shorts
  # playlist and YouTube says 404. A window that could not be *read* is a
  # nil window, not an empty one.
  alias Window = {ids: Array(String), oldest: Time?}

  def initialize(@db)
  end

  # Marker row recording the kinds the existing views were built for. Kept in
  # the database rather than in memory so a restart does no DDL: dropping and
  # recreating every view on each boot would race the feed refresh job and any
  # request reading a view at that moment, for no gain.
  APPLIED_KEY = "feed_kinds_applied"

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

  # ------------------------------------------------------------------
  #  Pass 1 — the feed windows
  # ------------------------------------------------------------------

  private def run_window_pass : Int32
    labelled = 0

    pending_channels.each do |ucid|
      begin
        shorts = feed_window(ucid, Invidious::ArikFeedKinds::KIND_SHORT)
        lives = feed_window(ucid, Invidious::ArikFeedKinds::KIND_LIVE)

        # A window we could not read leaves the channel for the next tick.
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
      # This channel posts neither Shorts nor streams, so elimination holds
      # for its whole history and the tail pass never has to see it.
      request = <<-SQL
        UPDATE channel_videos SET kind = $1
        WHERE ucid = $2 AND kind IS NULL
      SQL

      return labelled + PG_DB.exec(
        request, Invidious::ArikFeedKinds::KIND_VIDEO, ucid
      ).rows_affected.to_i32
    end

    # Otherwise elimination is only sound as far back as *both* windows saw:
    # the more recent of the two floors. Past that a row's absence proves
    # nothing — the window simply ended — so it is left to the tail pass.
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

  # ------------------------------------------------------------------
  #  Pass 2 — the tail
  # ------------------------------------------------------------------

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

  # ------------------------------------------------------------------
  #  YouTube
  # ------------------------------------------------------------------

  private def feed_window(ucid : String, kind : String) : Window?
    resource = Invidious::ArikFeedKinds.feed_resource(ucid, kind)
    return nil if resource.nil?

    sleep REQUEST_DELAY
    response = YT_POOL.client &.get(resource)

    # No uploads of this kind means no playlist, and YouTube says 404. That
    # is an answer, and an important one: it is what lets a channel that
    # posts nothing but long-form be closed out in a single tick.
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

  # ------------------------------------------------------------------
  #  Database
  # ------------------------------------------------------------------

  # Channels owing a label, the ones owing most first, so a channel that
  # posts a lot of Shorts is dealt with soonest.
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

  # Rows the window pass has already had its chance at. Newest first —
  # those are the ones a feed actually shows.
  private def pending_tail_videos : Array(String)
    request = <<-SQL
      SELECT id FROM channel_videos
      WHERE kind IS NULL
      ORDER BY published DESC
      LIMIT $1
    SQL

    PG_DB.query_all(request, PROBES_PER_TICK, as: String)
  end

  # Only ever writes over NULL. A label is never revised, so a later pass
  # cannot undo an answer the authoritative probe already gave.
  private def write_kind(ids : Array(String), kind : String) : Int32
    return 0 if ids.empty?

    request = <<-SQL
      UPDATE channel_videos SET kind = $1
      WHERE id = ANY($2) AND kind IS NULL
    SQL

    PG_DB.exec(request, kind, ids).rows_affected.to_i32
  end

  # Rebuilds the subscription views when, and only when, they no longer match
  # the configured kinds.
  #
  # The restriction is baked into a materialized view at CREATE time and
  # `REFRESH` re-runs that stored definition, so a view made before this
  # feature — or before the admin last changed the setting — keeps serving
  # every kind until it is recreated.
  private def reconcile_subscription_views : Nil
    wanted = CONFIG.feed_kinds.to_json
    return if Invidious::ArikSettings.fetch(APPLIED_KEY) == wanted && !stale_views?

    rebuild_subscription_views
    Invidious::ArikSettings.store(APPLIED_KEY, wanted)
  end

  # True when some view predates the `kind` column, so it cannot be carrying
  # the predicate whatever the marker claims. This is what makes a restored
  # backup heal itself instead of quietly serving Shorts for ever.
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

  # DROP and CREATE every subscription view, so each one carries the
  # predicate for the kinds currently configured.
  #
  # A user whose view cannot be rebuilt is logged and skipped rather than
  # aborting the pass: one broken view must not cost everybody else theirs.
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
