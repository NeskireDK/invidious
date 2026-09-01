require "../spec_helper"
require "../../src/invidious/arik_settings"

# Stand-ins for the running configuration. `merge_overrides!` and `apply_to`
# only need something carrying these properties, so override precedence is
# testable without a parsed config file and without Postgres.
private class FakeTrustedHeaderAuthConfig
  property enabled : Bool = false
  property header : String = "Remote-User"
  property trusted_proxies : Array(String) = [] of String
  property logout_url : String? = nil
  property password_self_service : Bool = true
  property auto_approve_token_callbacks : Array(String) = [] of String
end

private class FakeConfig
  property popular_playlists : Array(String) = [] of String
  property trending_playlists : Array(String) = [] of String
  property trusted_header_auth : FakeTrustedHeaderAuthConfig = FakeTrustedHeaderAuthConfig.new
  property feed_kinds : Array(String) = ["video"]
end

Spectator.describe Invidious::ArikSettings do
  alias Settings = Invidious::ArikSettings
  alias TrustedHeaderAuthSettings = Invidious::ArikSettings::TrustedHeaderAuthSettings

  # ------------------------------------------------------------------
  #  Override precedence
  # ------------------------------------------------------------------

  describe "override precedence" do
    it "keeps the environment config when no override is stored" do
      config = FakeConfig.new
      config.popular_playlists = ["IVPLenvironment"]
      config.trending_playlists = ["IVPLenvtrending"]
      config.trusted_header_auth.header = "X-Env-User"

      Settings.merge_overrides!(config, nil, nil, nil)

      expect(config.popular_playlists).to eq(["IVPLenvironment"])
      expect(config.trending_playlists).to eq(["IVPLenvtrending"])
      expect(config.trusted_header_auth.header).to eq("X-Env-User")
    end

    it "lets a stored value override the environment config" do
      config = FakeConfig.new
      config.popular_playlists = ["IVPLenvironment"]

      Settings.merge_overrides!(config, ["IVPLstored"], nil, nil)

      expect(config.popular_playlists).to eq(["IVPLstored"])
    end

    it "overrides only the keys that have a stored value" do
      config = FakeConfig.new
      config.popular_playlists = ["IVPLenvpopular"]
      config.trending_playlists = ["IVPLenvtrending"]

      Settings.merge_overrides!(config, ["IVPLstored"], nil, nil)

      expect(config.popular_playlists).to eq(["IVPLstored"])
      expect(config.trending_playlists).to eq(["IVPLenvtrending"])
    end

    it "treats a stored empty list as an override, not as absence" do
      config = FakeConfig.new
      config.popular_playlists = ["IVPLenvironment"]

      Settings.merge_overrides!(config, [] of String, nil, nil)

      # An empty list is what turns the stock feed back on
      expect(config.popular_playlists).to be_empty
    end

    it "overrides every field of the trusted-header block" do
      config = FakeConfig.new
      config.trusted_header_auth.enabled = false
      config.trusted_header_auth.header = "X-Env-User"
      config.trusted_header_auth.trusted_proxies = ["10.0.0.1"]
      config.trusted_header_auth.logout_url = "https://env.example.com/logout"

      stored = TrustedHeaderAuthSettings.new(
        enabled: true,
        header: "Remote-User",
        trusted_proxies: ["192.168.1.101"],
        logout_url: "https://auth.example.com/logout",
        password_self_service: false,
        auto_approve_token_callbacks: ["https://yt.example.com"]
      )

      Settings.merge_overrides!(config, nil, nil, stored)

      expect(config.trusted_header_auth.enabled).to be_true
      expect(config.trusted_header_auth.header).to eq("Remote-User")
      expect(config.trusted_header_auth.trusted_proxies).to eq(["192.168.1.101"])
      expect(config.trusted_header_auth.logout_url).to eq("https://auth.example.com/logout")
      expect(config.trusted_header_auth.password_self_service).to be_false
      expect(config.trusted_header_auth.auto_approve_token_callbacks).to eq(["https://yt.example.com"])
    end

    it "stores an empty logout URL as no logout URL" do
      config = FakeConfig.new
      config.trusted_header_auth.logout_url = "https://env.example.com/logout"

      Settings.merge_overrides!(config, nil, nil, TrustedHeaderAuthSettings.new(logout_url: ""))

      expect(config.trusted_header_auth.logout_url).to be_nil
    end
  end

  describe ".normalise_feed_kinds!" do
    it "cleans a config-file value, so the predicate and the marker agree" do
      config = FakeConfig.new
      config.feed_kinds = ["VIDEO", " video ", "bogus"]

      Settings.normalise_feed_kinds!(config)

      expect(config.feed_kinds).to eq(["video"])
    end

    it "orders and deduplicates whatever the file said" do
      config = FakeConfig.new
      config.feed_kinds = ["live", "short", "live"]

      Settings.normalise_feed_kinds!(config)

      expect(config.feed_kinds).to eq(["short", "live"])
    end

    it "runs on the config-file path, where no override is stored" do
      config = FakeConfig.new
      config.feed_kinds = ["Short"]

      Settings.merge_overrides!(config, nil, nil, nil, nil)

      expect(config.feed_kinds).to eq(["short"])
    end
  end

  # ------------------------------------------------------------------
  #  Decoding stored rows
  # ------------------------------------------------------------------

  describe ".decode_playlists" do
    it "reports no override for a missing row" do
      value, error = Settings.decode_playlists(nil)

      expect(value).to be_nil
      expect(error).to be_nil
    end

    it "decodes a stored list" do
      value, error = Settings.decode_playlists(%(["IVPLone","IVPLtwo"]))

      expect(value).to eq(["IVPLone", "IVPLtwo"])
      expect(error).to be_nil
    end

    it "ignores a row that is not JSON" do
      value, error = Settings.decode_playlists("IVPLone, IVPLtwo")

      expect(value).to be_nil
      expect(error).not_to be_nil
    end

    it "ignores a row that is not a list" do
      value, error = Settings.decode_playlists(%({"plid": "IVPLone"}))

      expect(value).to be_nil
      expect(error).not_to be_nil
    end

    it "ignores a row holding a malformed playlist ID" do
      value, error = Settings.decode_playlists(%(["IVPLone","not a plid"]))

      expect(value).to be_nil
      expect(error.to_s).to contain("not a valid playlist ID")
    end
  end

  describe ".decode_trusted_header_auth" do
    it "reports no override for a missing row" do
      value, error = Settings.decode_trusted_header_auth(nil)

      expect(value).to be_nil
      expect(error).to be_nil
    end

    it "decodes a valid block" do
      value, error = Settings.decode_trusted_header_auth(
        %({"enabled":true,"header":"Remote-User","trusted_proxies":["192.168.1.101"]})
      )

      expect(error).to be_nil
      expect(value.not_nil!.enabled).to be_true
      expect(value.not_nil!.trusted_proxies).to eq(["192.168.1.101"])
    end

    it "defaults password self service to on" do
      value, _error = Settings.decode_trusted_header_auth(%({"enabled":false}))

      expect(value.not_nil!.password_self_service).to be_true
    end

    it "ignores a block holding a CIDR range" do
      value, error = Settings.decode_trusted_header_auth(
        %({"enabled":true,"trusted_proxies":["192.168.1.0/24"]})
      )

      expect(value).to be_nil
      expect(error.to_s).to contain("CIDR")
    end

    it "ignores a block enabled without a trusted proxy" do
      value, error = Settings.decode_trusted_header_auth(%({"enabled":true,"trusted_proxies":[]}))

      expect(value).to be_nil
      expect(error.to_s).to contain("at least one trusted proxy")
    end

    it "ignores a row that is not JSON" do
      value, error = Settings.decode_trusted_header_auth("enabled = true")

      expect(value).to be_nil
      expect(error).not_to be_nil
    end
  end

  # ------------------------------------------------------------------
  #  Validators
  # ------------------------------------------------------------------

  describe ".trusted_proxy_error" do
    it "accepts a literal IPv4 address" do
      expect(Settings.trusted_proxy_error("192.168.1.101")).to be_nil
    end

    it "accepts a literal IPv6 address" do
      expect(Settings.trusted_proxy_error("::1")).to be_nil
    end

    it "refuses a CIDR range, which stops the instance from starting" do
      expect(Settings.trusted_proxy_error("192.168.1.0/24").to_s).to contain("CIDR")
    end

    it "refuses a single address written as a range" do
      expect(Settings.trusted_proxy_error("192.168.1.101/32").to_s).to contain("CIDR")
    end

    it "refuses a host name" do
      expect(Settings.trusted_proxy_error("proxy.example.com").to_s).to contain("not a valid IP address")
    end

    it "refuses an empty entry" do
      expect(Settings.trusted_proxy_error("   ")).not_to be_nil
    end
  end

  describe "TrustedHeaderAuthSettings#errors" do
    it "accepts a disabled block" do
      expect(TrustedHeaderAuthSettings.new.errors).to be_empty
    end

    it "accepts an enabled block with a literal proxy IP" do
      settings = TrustedHeaderAuthSettings.new(enabled: true, trusted_proxies: ["192.168.1.101"])

      expect(settings.errors).to be_empty
    end

    it "refuses being enabled with no trusted proxy" do
      settings = TrustedHeaderAuthSettings.new(enabled: true)

      expect(settings.errors.join).to contain("at least one trusted proxy")
    end

    it "refuses being enabled with only blank trusted proxies" do
      settings = TrustedHeaderAuthSettings.new(enabled: true, trusted_proxies: ["  "])

      expect(settings.errors.join).to contain("at least one trusted proxy")
    end

    it "refuses being enabled without a header name" do
      settings = TrustedHeaderAuthSettings.new(
        enabled: true, header: " ", trusted_proxies: ["192.168.1.101"]
      )

      expect(settings.errors.join).to contain("header name can't be empty")
    end

    it "refuses a bad proxy entry even while disabled" do
      settings = TrustedHeaderAuthSettings.new(enabled: false, trusted_proxies: ["192.168.1.0/24"])

      expect(settings.errors.join).to contain("CIDR")
    end

    it "refuses a relative logout URL" do
      settings = TrustedHeaderAuthSettings.new(logout_url: "/logout")

      expect(settings.errors.join).to contain("logout URL")
    end

    it "accepts an empty logout URL" do
      expect(TrustedHeaderAuthSettings.new(logout_url: "").errors).to be_empty
    end

    it "refuses a callback origin carrying a path" do
      settings = TrustedHeaderAuthSettings.new(
        auto_approve_token_callbacks: ["https://yt.example.com/callback"]
      )

      expect(settings.errors.join).to contain("without a path")
    end
  end

  describe ".origin_error" do
    it "accepts a bare https origin" do
      expect(Settings.origin_error("https://yt.example.com")).to be_nil
    end

    it "accepts a trailing slash" do
      expect(Settings.origin_error("https://yt.example.com/")).to be_nil
    end

    it "accepts an explicit port" do
      expect(Settings.origin_error("http://192.168.1.59:3000")).to be_nil
    end

    it "refuses a path" do
      expect(Settings.origin_error("https://yt.example.com/cb").to_s).to contain("without a path")
    end

    it "refuses a query string" do
      expect(Settings.origin_error("https://yt.example.com?a=1").to_s).to contain("query string")
    end

    it "refuses a fragment" do
      expect(Settings.origin_error("https://yt.example.com#x").to_s).to contain("fragment")
    end

    it "refuses credentials" do
      expect(Settings.origin_error("https://user@yt.example.com").to_s).to contain("credentials")
    end

    it "refuses a scheme that is not http or https" do
      expect(Settings.origin_error("ftp://yt.example.com").to_s).to contain("scheme")
    end

    it "refuses a value with no scheme at all" do
      expect(Settings.origin_error("yt.example.com").to_s).to contain("scheme")
    end

    it "refuses an empty entry" do
      expect(Settings.origin_error("  ")).not_to be_nil
    end
  end

  # ------------------------------------------------------------------
  #  Origin matching
  # ------------------------------------------------------------------

  describe ".origin_allowed?" do
    let(allowed) { ["https://yt.ariksen.dk"] }

    it "matches the same origin" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk/cb?state=1", allowed)).to be_true
    end

    it "matches whatever the path and query are" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk/a/b/c#frag", allowed)).to be_true
    end

    it "matches a differently cased host" do
      expect(Settings.origin_allowed?("https://YT.Ariksen.DK/cb", allowed)).to be_true
    end

    it "matches the scheme's default port written out" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk:443/cb", allowed)).to be_true
    end

    it "refuses a host that only starts with an allowed host" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk.evil.com/cb", allowed)).to be_false
    end

    it "refuses an allowed host hidden in the user info" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk@evil.com/cb", allowed)).to be_false
    end

    it "refuses an allowed host used as a password" do
      expect(Settings.origin_allowed?("https://user:yt.ariksen.dk@evil.com/cb", allowed)).to be_false
    end

    it "refuses an allowed origin hidden in the path" do
      expect(Settings.origin_allowed?("https://evil.com/https://yt.ariksen.dk", allowed)).to be_false
    end

    it "refuses an allowed origin hidden in the query" do
      expect(Settings.origin_allowed?("https://evil.com/?next=https://yt.ariksen.dk", allowed)).to be_false
    end

    it "refuses a subdomain of an allowed host" do
      expect(Settings.origin_allowed?("https://sub.yt.ariksen.dk/cb", allowed)).to be_false
    end

    it "refuses the same host on another scheme" do
      expect(Settings.origin_allowed?("http://yt.ariksen.dk/cb", allowed)).to be_false
    end

    it "refuses the same host on another port" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk:8443/cb", allowed)).to be_false
    end

    it "refuses a scheme that is not http or https" do
      expect(Settings.origin_allowed?("javascript://yt.ariksen.dk/cb", allowed)).to be_false
    end

    it "refuses everything while the list is empty" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk/cb", [] of String)).to be_false
    end

    it "refuses a missing callback URL" do
      expect(Settings.origin_allowed?(nil, allowed)).to be_false
    end

    it "matches an entry written with a trailing slash" do
      expect(Settings.origin_allowed?("https://yt.ariksen.dk/cb", ["https://yt.ariksen.dk/"])).to be_true
    end

    it "matches an entry with a non-default port" do
      expect(
        Settings.origin_allowed?("http://192.168.1.59:3000/cb", ["http://192.168.1.59:3000"])
      ).to be_true
    end
  end

  # ------------------------------------------------------------------
  #  Gating
  # ------------------------------------------------------------------

  describe ".auto_approve_token?" do
    let(allowed) { ["https://yt.ariksen.dk"] }
    let(callback) { "https://yt.ariksen.dk/cb" }

    it "approves an SSO session calling back to an allowed origin" do
      expect(
        Settings.auto_approve_token?(true, allowed, "a@example.com", "a@example.com", callback)
      ).to be_true
    end

    it "refuses while trusted-header authentication is off" do
      expect(
        Settings.auto_approve_token?(false, allowed, "a@example.com", "a@example.com", callback)
      ).to be_false
    end

    it "refuses while the list is empty" do
      expect(
        Settings.auto_approve_token?(true, [] of String, "a@example.com", "a@example.com", callback)
      ).to be_false
    end

    it "refuses a session the header does not vouch for" do
      expect(
        Settings.auto_approve_token?(true, allowed, nil, "a@example.com", callback)
      ).to be_false
    end

    it "refuses a header asserting somebody else" do
      expect(
        Settings.auto_approve_token?(true, allowed, "b@example.com", "a@example.com", callback)
      ).to be_false
    end

    it "refuses a callback outside the list" do
      expect(
        Settings.auto_approve_token?(true, allowed, "a@example.com", "a@example.com", "https://evil.com/cb")
      ).to be_false
    end

    it "refuses a request without a callback URL" do
      expect(
        Settings.auto_approve_token?(true, allowed, "a@example.com", "a@example.com", nil)
      ).to be_false
    end
  end

  describe ".password_self_service?" do
    it "waives the current password for an SSO session" do
      expect(Settings.password_self_service?(true, "a@example.com", "a@example.com")).to be_true
    end

    it "refuses while the flag is off" do
      expect(Settings.password_self_service?(false, "a@example.com", "a@example.com")).to be_false
    end

    it "refuses a session the header does not vouch for" do
      expect(Settings.password_self_service?(true, nil, "a@example.com")).to be_false
    end

    it "refuses a header asserting somebody else" do
      expect(Settings.password_self_service?(true, "b@example.com", "a@example.com")).to be_false
    end
  end

  # ------------------------------------------------------------------
  #  Playlist IDs
  # ------------------------------------------------------------------

  describe ".clean_playlist_ids" do
    it "keeps the given order" do
      plids, errors = Settings.clean_playlist_ids(["IVPLtwo", "IVPLone"])

      expect(plids).to eq(["IVPLtwo", "IVPLone"])
      expect(errors).to be_empty
    end

    it "drops duplicates and keeps the first position" do
      plids, _errors = Settings.clean_playlist_ids(["IVPLone", "IVPLtwo", "IVPLone"])

      expect(plids).to eq(["IVPLone", "IVPLtwo"])
    end

    it "drops blank lines and trims the rest" do
      plids, errors = Settings.clean_playlist_ids(["", "  IVPLone  ", "\t"])

      expect(plids).to eq(["IVPLone"])
      expect(errors).to be_empty
    end

    it "refuses an entry that is not a playlist ID" do
      plids, errors = Settings.clean_playlist_ids(["IVPLone", "https://example.com/list"])

      expect(plids).to eq(["IVPLone"])
      expect(errors.join).to contain("not a valid playlist ID")
    end

    it "accepts an empty list, which is the stock feed" do
      plids, errors = Settings.clean_playlist_ids([] of String)

      expect(plids).to be_empty
      expect(errors).to be_empty
    end
  end
end
