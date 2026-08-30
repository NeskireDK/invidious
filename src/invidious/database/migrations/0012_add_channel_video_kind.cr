module Invidious::Database::Migrations
  # Records what sort of thing a subscription feed entry is (ArikTube
  # extension). See `Invidious::ArikFeedKinds` for where the value comes from.
  #
  # Nullable with no default on purpose: NULL means "not classified yet", and
  # the feed shows those (see `ArikFeedKinds.visible?`). A default of 'video'
  # would make an unclassified Short indistinguishable from a confirmed
  # long-form upload, and the classifier could never tell which rows it still
  # owes an answer for.
  class AddChannelVideoKind < Migration
    version 12

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      ALTER TABLE public.channel_videos
        ADD COLUMN IF NOT EXISTS kind text;
      SQL

      # The classifier's own worklist query is "unclassified rows, by
      # channel", and the feed filters on kind. A partial index serves the
      # first and stays tiny, because the steady state is almost no NULLs.
      conn.exec <<-SQL
      CREATE INDEX IF NOT EXISTS channel_videos_unclassified_idx
        ON public.channel_videos
        USING btree (ucid COLLATE pg_catalog."default")
        WHERE kind IS NULL;
      SQL
    end
  end
end
