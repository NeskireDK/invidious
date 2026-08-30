require "json"
require "socket"
require "uri"

# Runtime-configurable settings (ArikTube extension).
#
# The fork's own knobs — playlist-backed feeds and trusted-header auth — are
# read from the YAML config. Production passes that config through the
# INVIDIOUS_CONFIG environment variable, so a `config.yml` written at runtime
# is thrown away on the next restart. These overrides live in the
# `arik_settings` table instead:
#
#   1. the environment config is parsed first and seeds every value,
#   2. a row in `arik_settings` overrides the value of its own key,
#   3. the admin settings page writes the row and applies it to the running
#      CONFIG, so a save takes effect without a restart.
#
# A row that is malformed or fails validation is reported and ignored, and the
# environment config stays authoritative for that key. A bad write can
# therefore never keep the instance from booting.
module Invidious::ArikSettings
  extend self

  # One row per key. A key without a row keeps the environment config value.
  KEY_POPULAR_PLAYLISTS   = "popular_playlists"
  KEY_TRENDING_PLAYLISTS  = "trending_playlists"
  KEY_TRUSTED_HEADER_AUTH = "trusted_header_auth"
  KEY_FEED_KINDS          = "feed_kinds"

  # Playlist IDs are opaque strings; this accepts both the local "IVPL…" and
  # the YouTube "PL…" shapes while rejecting anything with separators in it.
  PLAYLIST_ID_REGEX = /\A[A-Za-z0-9_-]{2,64}\z/

  # ------------------------------------------------------------------
  #  Validation (pure: no database, no configuration, no logger)
  # ------------------------------------------------------------------

  # Returns the reason `address` is not usable as a trusted proxy entry.
  #
  # A CIDR range is called out separately because it is the mistake that
  # hurts: `Config.check` rejects it and the process exits on the next boot,
  # long after the admin saved it here.
  def trusted_proxy_error(address : String) : String?
    value = address.strip

    return "A trusted proxy entry can't be empty" if value.empty?

    if value.includes?('/')
      return "Trusted proxy '#{value}' looks like a CIDR range. \
              Literal IP addresses only — a range stops the instance from starting."
    end

    return "Trusted proxy '#{value}' is not a valid IP address" if !Socket::IPAddress.valid?(value)

    nil
  end

  # Returns the reason `origin` is not usable as an allowed callback origin.
  #
  # An entry is an origin and nothing else, so that the comparison against a
  # callback URL stays a whole-value match and can't be widened by a path.
  def origin_error(origin : String) : String?
    value = origin.strip

    return "An allowed callback origin can't be empty" if value.empty?

    uri = begin
      URI.parse(value)
    rescue
      return "'#{value}' is not a valid URL"
    end

    scheme = uri.scheme.try &.downcase
    if scheme != "http" && scheme != "https"
      return "'#{value}' needs an http:// or https:// scheme"
    end

    host = uri.host
    return "'#{value}' needs a host name" if host.nil? || host.empty?

    if uri.user || uri.password
      return "'#{value}' must not carry credentials"
    end

    if !uri.path.empty? && uri.path != "/"
      return "'#{value}' must be an origin only (scheme, host and optional port), without a path"
    end

    return "'#{value}' must not carry a query string" if uri.query
    return "'#{value}' must not carry a fragment" if uri.fragment

    nil
  end

  # "scheme://host[:port]" of `url`, lowercased, with the scheme's default
  # port dropped. Returns nil when `url` has no usable origin.
  #
  # A URL that carries credentials is refused outright: "https://good@evil.tld"
  # is the classic way to make an origin look like something it is not.
  def normalize_origin(url : String) : String?
    uri = begin
      URI.parse(url.strip)
    rescue
      return nil
    end

    scheme = uri.scheme.try &.downcase
    return nil if scheme != "http" && scheme != "https"

    host = uri.host.try &.downcase
    return nil if host.nil? || host.empty?

    return nil if uri.user || uri.password

    port = uri.port
    port = nil if port == (scheme == "https" ? 443 : 80)

    port ? "#{scheme}://#{host}:#{port}" : "#{scheme}://#{host}"
  end

  # True when the origin of `callback_url` is literally one of `allowed`.
  #
  # Both sides are normalized and then compared whole, so neither a prefix
  # ("https://example.com.evil.tld") nor a path ("https://evil.tld/example.com")
  # can ever match an allowed entry.
  def origin_allowed?(callback_url : String?, allowed : Array(String)) : Bool
    return false if allowed.empty?
    return false if callback_url.nil?

    origin = normalize_origin(callback_url)
    return false if origin.nil?

    allowed.any? { |entry| normalize_origin(entry) == origin }
  end

  # Cleans a list of playlist IDs: blanks dropped, order kept, duplicates
  # dropped. Returns the cleaned list and a message for every entry refused.
  def clean_playlist_ids(entries : Array(String)) : {Array(String), Array(String)}
    cleaned = [] of String
    errors = [] of String

    entries.each do |entry|
      plid = entry.strip
      next if plid.empty?

      if !PLAYLIST_ID_REGEX.matches?(plid)
        errors << "'#{plid}' is not a valid playlist ID"
        next
      end

      cleaned << plid if !cleaned.includes?(plid)
    end

    {cleaned, errors}
  end

  # The current-password waiver for a `/change_password` request.
  #
  # The trusted header must assert the very identity the session belongs to,
  # and the admin must not have turned self service off.
  def password_self_service?(flag : Bool, asserted_email : String?, user_email : String) : Bool
    return false if !flag
    return false if asserted_email.nil?

    asserted_email == user_email
  end

  # Whether a token authorization request may skip the consent page.
  #
  # Every condition has to hold: header auth is on, the admin listed at least
  # one origin, this session was established by the trusted header for this
  # very user, and the callback lands on one of the listed origins.
  def auto_approve_token?(
    enabled : Bool,
    allowed : Array(String),
    asserted_email : String?,
    user_email : String,
    callback_url : String?,
  ) : Bool
    return false if !enabled
    return false if allowed.empty?
    return false if asserted_email.nil? || asserted_email != user_email

    origin_allowed?(callback_url, allowed)
  end

  # ------------------------------------------------------------------
  #  Stored shape
  # ------------------------------------------------------------------

  # The trusted-header block as it is stored and edited.
  #
  # Deliberately not `TrustedHeaderAuthConfig` itself: a stored block is
  # untrusted input and has to survive validation before it is allowed
  # anywhere near the running configuration.
  struct TrustedHeaderAuthSettings
    include JSON::Serializable

    property enabled : Bool = false
    property header : String = "Remote-User"
    property trusted_proxies : Array(String) = [] of String
    # "" means "no proxy logout URL", so the local sign-out form is used
    property logout_url : String = ""
    property password_self_service : Bool = true
    property auto_approve_token_callbacks : Array(String) = [] of String

    def initialize(
      @enabled : Bool = false,
      @header : String = "Remote-User",
      @trusted_proxies : Array(String) = [] of String,
      @logout_url : String = "",
      @password_self_service : Bool = true,
      @auto_approve_token_callbacks : Array(String) = [] of String,
    )
    end

    # Snapshot of a running `TrustedHeaderAuthConfig`
    def self.from_config(config) : self
      new(
        enabled: config.enabled,
        header: config.header,
        trusted_proxies: config.trusted_proxies.dup,
        logout_url: config.logout_url || "",
        password_self_service: config.password_self_service,
        auto_approve_token_callbacks: config.auto_approve_token_callbacks.dup,
      )
    end

    # Everything wrong with this block, empty when it is safe to store.
    def errors : Array(String)
      messages = [] of String

      if @enabled
        if @header.strip.empty?
          messages << "The header name can't be empty while trusted-header authentication is on"
        end

        if @trusted_proxies.none? { |address| !address.strip.empty? }
          messages << "Trusted-header authentication needs at least one trusted proxy IP. \
                       Without one the header would be honored from anywhere."
        end
      end

      # Checked even while disabled: a bad entry left behind here would stop
      # the instance from booting the moment somebody turns the feature on.
      @trusted_proxies.each do |address|
        if error = ArikSettings.trusted_proxy_error(address)
          messages << error
        end
      end

      logout_url = @logout_url.strip
      if !logout_url.empty?
        uri = URI.parse(logout_url) rescue nil
        scheme = uri.try &.scheme.try &.downcase
        if uri.nil? || (scheme != "http" && scheme != "https") || uri.host.to_s.empty?
          messages << "The logout URL must be an absolute http:// or https:// URL"
        end
      end

      @auto_approve_token_callbacks.each do |origin|
        if error = ArikSettings.origin_error(origin)
          messages << error
        end
      end

      messages
    end

    # Normalized copy: blanks dropped, values trimmed. Call before storing.
    def cleaned : self
      self.class.new(
        enabled: @enabled,
        header: @header.strip.presence || "Remote-User",
        trusted_proxies: @trusted_proxies.map(&.strip).reject(&.empty?).uniq,
        logout_url: @logout_url.strip,
        password_self_service: @password_self_service,
        auto_approve_token_callbacks: @auto_approve_token_callbacks.map(&.strip).reject(&.empty?).uniq,
      )
    end

    # Copies this block onto a running `TrustedHeaderAuthConfig`.
    def apply_to(config) : Nil
      config.enabled = @enabled
      config.header = @header
      config.trusted_proxies = @trusted_proxies
      config.logout_url = @logout_url.empty? ? nil : @logout_url
      config.password_self_service = @password_self_service
      config.auto_approve_token_callbacks = @auto_approve_token_callbacks
    end
  end

  # ------------------------------------------------------------------
  #  Decoding (pure: takes the stored text, never touches the database)
  # ------------------------------------------------------------------

  # Decodes a stored playlist list. Returns the list and nil, or nil and the
  # reason the row was ignored — an exception never leaves here, because a
  # single bad row must not stop the instance from booting.
  def decode_playlists(raw : String?) : {Array(String)?, String?}
    return {nil, nil} if raw.nil?

    plids = Array(String).from_json(raw)
    cleaned, errors = clean_playlist_ids(plids)
    return {nil, errors.join("; ")} if !errors.empty?

    {cleaned, nil}
  rescue ex
    {nil, "not a JSON list of playlist IDs (#{ex.message})"}
  end

  # Decodes a stored trusted-header block. An invalid block is refused here,
  # not at boot: `Config.check` already exited for a bad environment config,
  # and a bad database row must never do the same.
  def decode_trusted_header_auth(raw : String?) : {TrustedHeaderAuthSettings?, String?}
    return {nil, nil} if raw.nil?

    settings = TrustedHeaderAuthSettings.from_json(raw)
    errors = settings.errors
    return {nil, errors.join("; ")} if !errors.empty?

    {settings, nil}
  rescue ex
    {nil, "not a valid trusted_header_auth block (#{ex.message})"}
  end

  # Applies decoded overrides over `config`. A nil override leaves the key
  # alone, which is what makes the environment config the default and the
  # database the override.
  def merge_overrides!(
    config,
    popular_playlists : Array(String)?,
    trending_playlists : Array(String)?,
    trusted_header_auth : TrustedHeaderAuthSettings?,
    feed_kinds : Array(String)? = nil,
  ) : Nil
    config.popular_playlists = popular_playlists if popular_playlists
    config.trending_playlists = trending_playlists if trending_playlists
    trusted_header_auth.try &.apply_to(config.trusted_header_auth)
    config.feed_kinds = feed_kinds if feed_kinds
  end

  # ------------------------------------------------------------------
  #  Persistence
  # ------------------------------------------------------------------

  # The stored JSON text of `key`, or nil when there is no row. A database
  # that can't answer is reported and treated as "no override".
  def fetch(key : String) : String?
    PG_DB.query_one?("SELECT value::text FROM arik_settings WHERE key = $1", key, as: String)
  rescue ex
    LOGGER.error("ArikSettings: cannot read setting '#{key}' (#{ex.message})")
    nil
  end

  # Writes `json` as the value of `key`. Raises on failure so the caller can
  # tell the admin the save did not happen.
  def store(key : String, json : String) : Nil
    request = <<-SQL
      INSERT INTO arik_settings (key, value, updated)
      VALUES ($1, $2::jsonb, now())
      ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value, updated = EXCLUDED.updated
    SQL

    PG_DB.exec(request, key, json)
  end

  # Loads every override and applies it over `config`. Called once at boot,
  # after the environment config is parsed and validated.
  def apply_overrides!(config = CONFIG) : Nil
    popular, popular_error = decode_playlists(fetch(KEY_POPULAR_PLAYLISTS))
    trending, trending_error = decode_playlists(fetch(KEY_TRENDING_PLAYLISTS))
    trusted_header_auth, tha_error = decode_trusted_header_auth(fetch(KEY_TRUSTED_HEADER_AUTH))
    feed_kinds, feed_kinds_error = ArikFeedKinds.decode_kinds(fetch(KEY_FEED_KINDS))

    if error = popular_error
      LOGGER.error("ArikSettings: ignoring stored '#{KEY_POPULAR_PLAYLISTS}' — #{error}")
    end
    if error = trending_error
      LOGGER.error("ArikSettings: ignoring stored '#{KEY_TRENDING_PLAYLISTS}' — #{error}")
    end
    if error = tha_error
      LOGGER.error("ArikSettings: ignoring stored '#{KEY_TRUSTED_HEADER_AUTH}' — #{error}")
    end
    if error = feed_kinds_error
      LOGGER.error("ArikSettings: ignoring stored '#{KEY_FEED_KINDS}' — #{error}")
    end

    merge_overrides!(config, popular, trending, trusted_header_auth, feed_kinds)
  end
end
