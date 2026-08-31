# Playlist-backed Trending/Popular feeds (ArikTube extension).
#
# On a personal instance "Trending" and "Popular" mean "what this server's
# owner pushes". When `trending_playlists` / `popular_playlists` name local
# playlists, those feeds serve the merged playlist content instead. Public or
# unlisted both qualify: naming the plid in the config is the operator's
# decision to publish it, and unlisted already means "readable with the id".
# The swap happens at the data layer (fetch_trending / popular_videos), so
# the HTML views and /api/v1/trending|popular emit the same items and every
# API client shows them without client-side support.
module Invidious::PlaylistFeeds
  extend self

  # Merged videos of the configured playlists: config order, each playlist
  # in its own order, duplicates dropped. Missing or private playlists are
  # skipped with a log line so one bad entry cannot break the feed.
  def feed_videos(plids : Array(String)) : Array(SearchVideo)
    playlist_videos = [] of PlaylistVideo
    seen = Set(String).new

    plids.each do |plid|
      playlist = Invidious::Database::Playlists.select(id: plid)
      if playlist.nil?
        LOGGER.warn("PlaylistFeeds: playlist #{plid} does not exist, skipping")
        next
      end
      unless playlist.privacy.feedable?
        LOGGER.warn("PlaylistFeeds: playlist #{plid} is private, skipping")
        next
      end

      Invidious::Database::PlaylistVideos.select(plid, playlist.index, 0, limit: 200).each do |video|
        next if seen.includes?(video.id)
        seen << video.id
        playlist_videos << video
      end
    end

    views = view_counts(seen.to_a)
    playlist_videos.map { |video| as_search_video(video, views[video.id]? || 0_i64) }
  end

  # The playlist tables store no view counts, but the companion suggestion bot
  # keeps a permanent metadata cache in the same database. That `suggest`
  # schema belongs to the bot and is absent on a fresh install of this fork, so
  # a failed lookup costs the view counts only, never the feed itself.
  private def view_counts(ids : Array(String)) : Hash(String, Int64)
    return {} of String => Int64 if ids.empty?

    request = <<-SQL
      SELECT vid, views FROM suggest.video_meta
      WHERE views IS NOT NULL AND vid = ANY($1)
    SQL

    PG_DB.query_all(request, ids, as: {String, Int64}).to_h
  rescue ex
    LOGGER.debug("PlaylistFeeds: no view counts from suggest.video_meta (#{ex.message})")
    {} of String => Int64
  end

  # PlaylistVideo lacks description/thumbnails metadata; neutral defaults keep
  # the SearchVideo JSON shape the feed endpoints promise.
  private def as_search_video(video : PlaylistVideo, views : Int64) : SearchVideo
    SearchVideo.new({
      title:              video.title,
      id:                 video.id,
      author:             video.author,
      ucid:               video.ucid,
      published:          video.published,
      views:              views,
      description_html:   "",
      length_seconds:     video.length_seconds,
      premiere_timestamp: nil,
      author_verified:    false,
      author_thumbnail:   nil,
      badges:             video.live_now ? VideoBadges::LiveNow : VideoBadges::None,
    })
  end
end
