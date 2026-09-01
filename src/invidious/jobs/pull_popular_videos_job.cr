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
      # Jobs are bare `spawn`, with no supervisor: an exception escaping here
      # kills the fiber, and the snapshot then serves its last value for ever
      # -- or an empty list, if the first pass is the one that raised.
      begin
        refresh
      rescue ex
        LOGGER.error("PullPopularVideosJob: #{ex.message}")
      end

      sleep 1.minute
      Fiber.yield
    end
  end

  # Read every pass: popular_playlists is editable at runtime from the
  # ArikTube settings page.
  private def refresh : Nil
    if CONFIG.popular_playlists.empty?
      videos = Invidious::Database::ChannelVideos.select_popular_videos
        .sort_by!(&.published)
        .reverse!

      POPULAR_VIDEOS.set(videos)
    else
      POPULAR_PLAYLIST_VIDEOS.set(Invidious::PlaylistFeeds.feed_videos(CONFIG.popular_playlists))
    end
  end
end
