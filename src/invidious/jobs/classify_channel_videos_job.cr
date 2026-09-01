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
# and the ones too fresh to eliminate (see SHORTS_FEED_LAG). The probe answers
# short/not-short only, so a stream VOD looks exactly like a long-form upload
# to it and the tail pass has to leave `live` to the windows.
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

  # Nothing probes for `live`: a stream VOD and a long-form upload are the same
  # redirect. So the tail pass's long-form answer waits for the UULV window to
  # have had a chance to claim the row, on the assumption — unmeasured, unlike
  # SHORTS_FEED_LAG — that the UULV feed lags publication like the UUSH one.
  LIVE_FEED_LAG = SHORTS_FEED_LAG

  # `oldest` nil means the window carried nothing, which is a valid answer —
  # no uploads of that kind, so YouTube 404s the playlist. A window that could
  # not be *read* is a nil window.
  alias Window = {ids: Array(String), oldest: Time?}

  # A tail-pass candidate. The date decides whether the probe's long-form
  # answer may be trusted yet, so it is read with the id.
  alias TailRow = {id: String, published: Time?}

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
        labelled, windows_read = run_window_pass
        classified = labelled + run_tail_pass(windows_read)
        LOGGER.debug("ClassifyChannelVideosJob: classified #{classified} video(s)")
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: #{ex.message}")
      end

      sleep INTERVAL
    end
  end

  # Also hands back the channels whose windows it managed to read, which are
  # the only ones the tail pass may answer for.
  private def run_window_pass : {Int32, Array(String)}
    labelled = 0
    windows_read = [] of String

    pending_channels.each do |ucid|
      begin
        shorts = feed_window(ucid, Invidious::ArikFeedKinds::KIND_SHORT)
        lives = feed_window(ucid, Invidious::ArikFeedKinds::KIND_LIVE)

        # Eliminating against a half-read pair would call a Short long-form.
        next if shorts.nil? || lives.nil?

        windows_read << ucid
        changed = apply_window(ucid, shorts, lives)
        mark_feeds_stale([ucid]) if changed > 0
        labelled += changed
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: #{ucid} : #{ex.message}")
      end
    end

    {labelled, windows_read}
  end

  private def apply_window(ucid : String, shorts : Window, lives : Window) : Int32
    labelled = correct_kind(shorts[:ids], Invidious::ArikFeedKinds::KIND_SHORT)
    labelled += correct_kind(lives[:ids] - shorts[:ids], Invidious::ArikFeedKinds::KIND_LIVE)

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

  # Only the channels `run_window_pass` just read, so the windows have already
  # claimed every Short and stream VOD they carry before a probe can guess at
  # one. Table-wide, the probe could reach a VOD in a channel whose UULV feed
  # nobody had looked at yet.
  private def run_tail_pass(windows_read : Array(String)) : Int32
    labelled = 0
    written = [] of String

    pending_tail_videos(windows_read).each do |row|
      begin
        kind = probe_kind(row[:id])
        next if kind.nil?
        next if kind == Invidious::ArikFeedKinds::KIND_VIDEO && !long_form_settled?(row[:published])

        if write_kind([row[:id]], kind) > 0
          labelled += 1
          written << row[:id]
        end
      rescue ex
        LOGGER.error("ClassifyChannelVideosJob: probe #{row[:id]} : #{ex.message}")
      end
    end

    mark_feeds_stale(channels_of(written))
    labelled
  end

  # Whether the UULV window has had long enough to claim this row, so that
  # "not a Short" can be read as long-form. A row with no date is not waiting
  # on a window and never will be, so it is settled rather than held back --
  # holding it back would leave it unlabelled for ever and, because
  # `pending_channels` ranks by how many NULL rows a channel has, would pin its
  # channel and starve the rest.
  private def long_form_settled?(published : Time?) : Bool
    return true if published.nil?

    published < Time.utc - LIVE_FEED_LAG
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
    Invidious::ArikFeedKinds.kind_from_probe(response.status_code, response.headers["location"]?, id)
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

  private def pending_tail_videos(ucids : Array(String)) : Array(TailRow)
    return [] of TailRow if ucids.empty?

    request = <<-SQL
      SELECT id, published FROM channel_videos
      WHERE kind IS NULL AND ucid = ANY($1)
      ORDER BY (published IS NULL OR published < $3) DESC, published DESC NULLS FIRST
      LIMIT $2
    SQL

    PG_DB.query_all(request, ucids, PROBES_PER_TICK, Time.utc - LIVE_FEED_LAG,
      as: {id: String, published: Time?})
  end

  # An inference, so it only ever writes over NULL: a probe that guessed must
  # not be able to undo a window's answer.
  private def write_kind(ids : Array(String), kind : String) : Int32
    return 0 if ids.empty?

    request = <<-SQL
      UPDATE channel_videos SET kind = $1
      WHERE id = ANY($2) AND kind IS NULL
    SQL

    PG_DB.exec(request, kind, ids).rows_affected.to_i32
  end

  # YouTube's own per-kind uploads playlist named these rows, so this overrides
  # whatever an inference put there — the `kind IS NULL` gate on the window's
  # answer is what used to freeze a probe's guess for good.
  #
  # `IS DISTINCT FROM` covers NULL as well, and keeps rows_affected to the rows
  # that really changed, which is what mark_feeds_stale keys off.
  private def correct_kind(ids : Array(String), kind : String) : Int32
    return 0 if ids.empty?

    request = <<-SQL
      UPDATE channel_videos SET kind = $1
      WHERE id = ANY($2) AND kind IS DISTINCT FROM $1
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
