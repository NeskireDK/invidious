# Playlist-backed Trending/Popular feeds (ArikTube extension).
#
# On a personal instance "Trending" and "Popular" mean "what this server's
# owner pushes". When `trending_playlists` / `popular_playlists` name local
# public playlists, those feeds serve the merged playlist content instead.
# The swap happens at the data layer (fetch_trending / popular_videos), so
# the HTML views and /api/v1/trending|popular emit the same items and every
# API client shows them without client-side support.
module Invidious::PlaylistFeeds
  extend self

  # Merged videos of the configured playlists: config order, each playlist
  # in its own order, duplicates dropped. Missing or non-public playlists
  # are skipped with a log line so one bad entry cannot break the feed.
  def feed_videos(plids : Array(String)) : Array(SearchVideo)
    videos = [] of SearchVideo
    seen = Set(String).new

    plids.each do |plid|
      playlist = Invidious::Database::Playlists.select(id: plid)
      if playlist.nil?
        LOGGER.warn("PlaylistFeeds: playlist #{plid} does not exist, skipping")
        next
      end
      if playlist.privacy != PlaylistPrivacy::Public
        LOGGER.warn("PlaylistFeeds: playlist #{plid} is not public, skipping")
        next
      end

      Invidious::Database::PlaylistVideos.select(plid, playlist.index, 0, limit: 200).each do |video|
        next if seen.includes?(video.id)
        seen << video.id
        videos << as_search_video(video)
      end
    end

    videos
  end

  # PlaylistVideo lacks views/description/thumbnails metadata; neutral
  # defaults keep the SearchVideo JSON shape the feed endpoints promise.
  private def as_search_video(video : PlaylistVideo) : SearchVideo
    SearchVideo.new({
      title:              video.title,
      id:                 video.id,
      author:             video.author,
      ucid:               video.ucid,
      published:          video.published,
      views:              0_i64,
      description_html:   "",
      length_seconds:     video.length_seconds,
      premiere_timestamp: nil,
      author_verified:    false,
      author_thumbnail:   nil,
      badges:             video.live_now ? VideoBadges::LiveNow : VideoBadges::None,
    })
  end
end
