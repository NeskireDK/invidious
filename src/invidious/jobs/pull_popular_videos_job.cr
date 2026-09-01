class Invidious::Jobs::PullPopularVideosJob < Invidious::Jobs::BaseJob
  POPULAR_VIDEOS = Atomic.new([] of ChannelVideo)

  # ArikTube: the playlist-backed Popular feed, refreshed on the same minute.
  # Its own snapshot because a playlist feed is Array(SearchVideo), not
  # Array(ChannelVideo).
  POPULAR_PLAYLIST_VIDEOS = Atomic.new([] of SearchVideo)

  private getter db : DB::Database

  def initialize(@db)
  end

  def begin
    loop do
      # Read every pass: popular_playlists is editable at runtime from the
      # ArikTube settings page.
      if CONFIG.popular_playlists.empty?
        videos = Invidious::Database::ChannelVideos.select_popular_videos
          .sort_by!(&.published)
          .reverse!

        POPULAR_VIDEOS.set(videos)
      else
        POPULAR_PLAYLIST_VIDEOS.set(Invidious::PlaylistFeeds.feed_videos(CONFIG.popular_playlists))
      end

      sleep 1.minute
      Fiber.yield
    end
  end
end
