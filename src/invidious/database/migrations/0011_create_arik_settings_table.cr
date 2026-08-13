module Invidious::Database::Migrations
  class CreateArikSettingsTable < Migration
    version 11

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      CREATE TABLE IF NOT EXISTS public.arik_settings
      (
        key text NOT NULL,
        value jsonb NOT NULL,
        updated timestamp with time zone,
        CONSTRAINT arik_settings_key_key PRIMARY KEY (key)
      );
      SQL
    end
  end
end
