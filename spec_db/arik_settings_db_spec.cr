require "./db_spec_helper"
require "../src/invidious/arik_feed_kinds"
require "../src/invidious/arik_settings"

# `store` writes JSON text into a `jsonb` column and `fetch` reads it back with
# `value::text`. PostgreSQL is free to rewrite that text on the way through --
# it drops insignificant whitespace and reorders object keys -- so the two only
# agree through a decoder. Nothing under spec/ can reach this, and the per-view
# feed-kinds marker bug lived exactly here.
private module Stored
  extend self

  def playlists(key)
    Invidious::ArikSettings.decode_playlists(Invidious::ArikSettings.fetch(key))
  end

  def written_within_the_minute?(key) : Bool
    PG_DB.query_one(
      "SELECT updated > now() - interval '1 minute' FROM arik_settings WHERE key = $1",
      key, as: Bool)
  end

  def rows(key) : Int64
    PG_DB.query_one("SELECT count(*) FROM arik_settings WHERE key = $1", key, as: Int64)
  end
end

Spectator.describe "arik_settings over a real database" do
  alias Settings = Invidious::ArikSettings
  alias FeedKinds = Invidious::ArikFeedKinds

  before_each { PG_DB.exec("DELETE FROM arik_settings") }

  describe "a key with no row" do
    it "reads as nil rather than as an error" do
      expect(Settings.fetch(Settings::KEY_POPULAR_PLAYLISTS)).to be_nil
    end

    it "decodes to no override and no error" do
      expect(Stored.playlists(Settings::KEY_POPULAR_PLAYLISTS)).to eq({nil, nil})
    end
  end

  describe "a list of playlist IDs" do
    it "reads back as what was written" do
      Settings.store(Settings::KEY_POPULAR_PLAYLISTS, ["IVPLone", "IVPLtwo"].to_json)

      expect(Stored.playlists(Settings::KEY_POPULAR_PLAYLISTS))
        .to eq({["IVPLone", "IVPLtwo"], nil})
    end

    it "keeps its order" do
      Settings.store(Settings::KEY_TRENDING_PLAYLISTS, ["IVPLb", "IVPLa", "IVPLc"].to_json)

      expect(Stored.playlists(Settings::KEY_TRENDING_PLAYLISTS).first)
        .to eq(["IVPLb", "IVPLa", "IVPLc"])
    end

    it "survives text the column will rewrite on the way in" do
      Settings.store(Settings::KEY_POPULAR_PLAYLISTS, %([  "IVPLone" ,\n  "IVPLtwo"  ]))

      expect(Stored.playlists(Settings::KEY_POPULAR_PLAYLISTS))
        .to eq({["IVPLone", "IVPLtwo"], nil})
    end

    it "reads an empty list back as an empty list, not as no row" do
      Settings.store(Settings::KEY_POPULAR_PLAYLISTS, ([] of String).to_json)

      expect(Stored.playlists(Settings::KEY_POPULAR_PLAYLISTS)).to eq({[] of String, nil})
    end

    it "is one row per key, and the second write wins" do
      Settings.store(Settings::KEY_POPULAR_PLAYLISTS, ["IVPLfirst"].to_json)
      Settings.store(Settings::KEY_POPULAR_PLAYLISTS, ["IVPLsecond"].to_json)

      expect(Stored.rows(Settings::KEY_POPULAR_PLAYLISTS)).to eq(1_i64)
      expect(Stored.playlists(Settings::KEY_POPULAR_PLAYLISTS).first).to eq(["IVPLsecond"])
    end

    it "stamps the row so the admin page can say when it changed" do
      Settings.store(Settings::KEY_POPULAR_PLAYLISTS, ["IVPLone"].to_json)

      expect(Stored.written_within_the_minute?(Settings::KEY_POPULAR_PLAYLISTS)).to be_true
    end
  end

  describe "the trusted-header block" do
    it "reads back every field, whatever order the column stores them in" do
      written = Settings::TrustedHeaderAuthSettings.new(
        enabled: true,
        header: "Remote-User",
        trusted_proxies: ["192.168.1.101"],
        logout_url: "https://auth.example.com/logout",
        password_self_service: false,
        auto_approve_token_callbacks: ["https://yt.example.com"]
      )
      Settings.store(Settings::KEY_TRUSTED_HEADER_AUTH, written.to_json)

      read, error = Settings.decode_trusted_header_auth(
        Settings.fetch(Settings::KEY_TRUSTED_HEADER_AUTH))

      expect(error).to be_nil
      expect(read.try(&.enabled)).to be_true
      expect(read.try(&.header)).to eq("Remote-User")
      expect(read.try(&.trusted_proxies)).to eq(["192.168.1.101"])
      expect(read.try(&.logout_url)).to eq("https://auth.example.com/logout")
      expect(read.try(&.password_self_service)).to be_false
      expect(read.try(&.auto_approve_token_callbacks)).to eq(["https://yt.example.com"])
    end
  end

  describe "the feed kinds" do
    it "reads back as what was written" do
      Settings.store(Settings::KEY_FEED_KINDS, ["video", "short"].to_json)

      expect(FeedKinds.decode_kinds(Settings.fetch(Settings::KEY_FEED_KINDS)))
        .to eq({["video", "short"], nil})
    end

    it "reports a stored kind that is not one, instead of applying it" do
      Settings.store(Settings::KEY_FEED_KINDS, ["video", "reel"].to_json)

      kinds, error = FeedKinds.decode_kinds(Settings.fetch(Settings::KEY_FEED_KINDS))

      expect(kinds).to be_nil
      expect(error).not_to be_nil
    end

    it "reports a row that is not a JSON list at all" do
      PG_DB.exec("INSERT INTO arik_settings (key, value, updated) VALUES ($1, $2::jsonb, now())",
        Settings::KEY_FEED_KINDS, %({"kinds": ["video"]}))

      kinds, error = FeedKinds.decode_kinds(Settings.fetch(Settings::KEY_FEED_KINDS))

      expect(kinds).to be_nil
      expect(error).not_to be_nil
    end
  end
end
