module Invidious::Database::Migrations
  # Content kind of a subscription feed entry. See `Invidious::ArikFeedKinds`.
  #
  # Nullable with no default: NULL means "not classified yet" and the feed
  # shows those. A default of 'video' would hide which rows still owe an
  # answer.
  class AddChannelVideoKind < Migration
    version 12

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      ALTER TABLE public.channel_videos
        ADD COLUMN IF NOT EXISTS kind text;
      SQL

      conn.exec <<-SQL
      CREATE INDEX IF NOT EXISTS channel_videos_unclassified_idx
        ON public.channel_videos
        USING btree (ucid COLLATE pg_catalog."default")
        WHERE kind IS NULL;
      SQL
    end
  end
end
