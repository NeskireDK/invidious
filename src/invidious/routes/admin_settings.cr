{% skip_file if flag?(:api_only) %}

# Admin settings page for the ArikTube extensions.
#
# Nothing here is written to config.yml: production passes the config through
# INVIDIOUS_CONFIG, so a written file would be thrown away on the next
# restart. A save validates the form, writes the rows of the arik_settings
# table and applies the values to the running CONFIG, so it takes effect at
# once and survives the restart.
module Invidious::Routes::AdminSettings
  extend self

  # Show the settings form (GET request)
  def show(env)
    locale = env.get("preferences").as(Preferences).locale
    referer = get_referer(env, "/preferences")

    user = env.get?("user")
    if !user
      return env.redirect "/login?referer=#{URI.encode_path_segment(env.request.resource)}"
    end

    user = user.as(User)
    if !CONFIG.admins.includes?(user.email)
      return error_template(403, "Administrator privileges are required to open this page")
    end

    sid = env.get("sid").as(String)
    csrf_token = generate_response(sid, {":admin/settings"}, HMAC_KEY)

    playlists = self.public_playlists
    popular = CONFIG.popular_playlists
    trending = CONFIG.trending_playlists
    trusted_header_auth = ArikSettings::TrustedHeaderAuthSettings.from_config(CONFIG.trusted_header_auth)
    feed_kinds = CONFIG.feed_kinds

    saved = false
    errors = [] of String
    warnings = self.playlist_warnings(popular + trending)

    templated "admin/settings"
  end

  # Validate, store and apply the settings (POST request)
  def update(env)
    locale = env.get("preferences").as(Preferences).locale
    referer = get_referer(env, "/preferences")

    user = env.get?("user")
    if !user
      return env.redirect "/login?referer=#{URI.encode_path_segment(env.request.resource)}"
    end

    user = user.as(User)
    if !CONFIG.admins.includes?(user.email)
      return error_template(403, "Administrator privileges are required to open this page")
    end

    sid = env.get("sid").as(String)

    begin
      validate_request(env.params.body["csrf_token"]?, sid, env.request, HMAC_KEY, locale)
    rescue ex
      return error_template(400, ex)
    end

    csrf_token = generate_response(sid, {":admin/settings"}, HMAC_KEY)
    playlists = self.public_playlists

    errors = [] of String
    saved = false

    popular, popular_errors = self.submitted_playlists(env, "popular", playlists)
    trending, trending_errors = self.submitted_playlists(env, "trending", playlists)
    errors.concat(popular_errors)
    errors.concat(trending_errors)

    trusted_header_auth = self.submitted_trusted_header_auth(env).cleaned
    errors.concat(trusted_header_auth.errors)

    feed_kinds, feed_kind_errors = ArikFeedKinds.clean_kinds(env.params.body.fetch_all("feed_kind[]"))
    errors.concat(feed_kind_errors.map { |error| "Subscription feed content: #{error}" })

    # Nothing is stored while anything is wrong: a half-applied trusted-header
    # block is exactly the state this page exists to prevent.
    if errors.empty?
      begin
        ArikSettings.store(ArikSettings::KEY_POPULAR_PLAYLISTS, popular.to_json)
        ArikSettings.store(ArikSettings::KEY_TRENDING_PLAYLISTS, trending.to_json)
        ArikSettings.store(ArikSettings::KEY_TRUSTED_HEADER_AUTH, trusted_header_auth.to_json)
        ArikSettings.store(ArikSettings::KEY_FEED_KINDS, feed_kinds.to_json)

        CONFIG.popular_playlists = popular
        CONFIG.trending_playlists = trending
        trusted_header_auth.apply_to(CONFIG.trusted_header_auth)
        # ClassifyChannelVideosJob notices the change and rebuilds every
        # subscription view on its next tick — the views bake the predicate
        # in at CREATE time, so a REFRESH would not pick this up.
        CONFIG.feed_kinds = feed_kinds

        saved = true
        LOGGER.info("AdminSettings: #{user.email} updated the ArikTube settings")
      rescue ex
        errors << "The settings could not be stored: #{ex.message}"
      end
    end

    # A playlist that does not resolve is reported, not refused: the feed
    # skips it the same way, and an admin may well be listing a playlist
    # they are about to create.
    warnings = self.playlist_warnings(popular + trending)

    templated "admin/settings"
  end

  # ------------------------------------------------------------------
  #  Form reading
  # ------------------------------------------------------------------

  # The playlist IDs submitted for one feed.
  #
  # The tick boxes carry the selection and the number beside each one carries
  # the position; entries without a number fall to the end, in the order the
  # playlists are listed. The text area below takes IDs that are not local
  # playlists at all, and is appended after the ticked ones.
  private def submitted_playlists(env, prefix : String, playlists) : {Array(String), Array(String)}
    selected = env.params.body.fetch_all("#{prefix}_playlist[]")

    ordered = selected.map_with_index { |plid, index| {plid, index} }
      .sort_by do |(plid, index)|
        position = env.params.body["#{prefix}_order[#{plid}]"]?.try &.to_i?
        {position || Int32::MAX, index}
      end
      .map { |(plid, _index)| plid }

    extra = (env.params.body["#{prefix}_extra"]? || "").lines

    plids, errors = ArikSettings.clean_playlist_ids(ordered + extra)
    {plids, errors.map { |error| "#{prefix.capitalize}: #{error}" }}
  end

  private def submitted_trusted_header_auth(env) : ArikSettings::TrustedHeaderAuthSettings
    ArikSettings::TrustedHeaderAuthSettings.new(
      enabled: env.params.body["tha_enabled"]? == "on",
      header: env.params.body["tha_header"]? || "Remote-User",
      trusted_proxies: (env.params.body["tha_trusted_proxies"]? || "").lines,
      logout_url: env.params.body["tha_logout_url"]? || "",
      password_self_service: env.params.body["tha_password_self_service"]? == "on",
      auto_approve_token_callbacks: (env.params.body["tha_auto_approve"]? || "").lines,
    )
  end

  # ------------------------------------------------------------------
  #  Playlist lookups
  # ------------------------------------------------------------------

  # The public playlists of this instance, for the tick-box lists. A database
  # that can't answer costs the lists, not the page.
  private def public_playlists : Array(InvidiousPlaylist)
    Invidious::Database::Playlists.select_public
  rescue ex
    LOGGER.error("AdminSettings: cannot list public playlists (#{ex.message})")
    [] of InvidiousPlaylist
  end

  # One message per configured playlist the feeds will skip.
  private def playlist_warnings(plids : Array(String)) : Array(String)
    plids.uniq.compact_map do |plid|
      playlist = Invidious::Database::Playlists.select(id: plid)

      if playlist.nil?
        "Playlist #{plid} does not exist on this instance and will be skipped"
      elsif playlist.privacy != PlaylistPrivacy::Public
        "Playlist #{plid} is not public and will be skipped"
      end
    end
  rescue ex
    LOGGER.error("AdminSettings: cannot check the configured playlists (#{ex.message})")
    [] of String
  end
end
