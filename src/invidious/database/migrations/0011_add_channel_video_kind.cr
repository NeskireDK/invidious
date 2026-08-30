module Invidious::Database::Migrations
  # Content kind of a subscription feed entry. See `Invidious::FeedKinds`.
  #
  # Nullable with no default: NULL means "not classified yet" and the feed
  # shows those. A default of 'video' would hide which rows still owe an
  # answer.
  class AddChannelVideoKind < Migration
    version 11

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

      # Records which kinds the subscription views were last built for, so a
      # restart does no DDL. A materialized view bakes its predicate in at
      # CREATE time, so the value cannot be read back off the view.
      conn.exec <<-SQL
      CREATE TABLE IF NOT EXISTS public.feed_kind_state
      (
        key text NOT NULL,
        value text,
        updated timestamp with time zone,
        CONSTRAINT feed_kind_state_key_key PRIMARY KEY (key)
      );
      SQL
    end
  end
end
