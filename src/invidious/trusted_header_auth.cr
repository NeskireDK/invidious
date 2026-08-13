# Trusted-header authentication (ArikTube extension).
#
# An authenticating reverse proxy (Authelia behind Traefik) asserts the user
# name in a request header. The header is only honored when the TCP peer is
# listed in `trusted_proxies` — never based on X-Forwarded-For. The account
# is provisioned on first sight, so a browser with a proxy session never
# sees the Invidious login form.
#
# The reverse proxy MUST strip the configured header from client requests on
# every route that bypasses its authentication, or clients can impersonate
# users through those routes.
module Invidious::TrustedHeaderAuth
  extend self

  # "::ffff:192.168.1.101" and "192.168.1.101" are the same peer
  private def normalize_ip(address : String) : String
    address.lchop("::ffff:")
  end

  private def trusted_peer?(env) : Bool
    remote = env.request.remote_address.as?(Socket::IPAddress)
    return false unless remote

    peer = normalize_ip(remote.address)
    CONFIG.trusted_header_auth.trusted_proxies.any? { |address| normalize_ip(address) == peer }
  end

  # The user name asserted by the proxy, or nil when absent or untrusted.
  def asserted_email(env) : String?
    config = CONFIG.trusted_header_auth
    return nil unless config.enabled

    # API clients (Yattee, bots) authenticate with tokens only
    return nil if env.request.path.starts_with?("/api/")

    values = env.request.headers.get?(config.header)
    return nil unless values
    # A duplicated header is an attack indicator: reject the request
    return nil if values.size != 1

    email = values[0].strip.downcase.byte_slice(0, 254)
    return nil if email.empty?
    return nil unless trusted_peer?(env)

    email
  end

  # Whether a token authorization request may skip the consent page.
  #
  # Only for a session the proxy vouches for, and only when the callback
  # lands on an origin the admin listed. The token still goes to that origin
  # and nowhere else, so an attacker who talks the browser into this route
  # hands the token to the admin's own client, not to themselves.
  def auto_approve_token?(env, user, callback_url : String?) : Bool
    config = CONFIG.trusted_header_auth

    Invidious::ArikSettings.auto_approve_token?(
      config.enabled,
      config.auto_approve_token_callbacks,
      asserted_email(env),
      user.email,
      callback_url
    )
  end

  # Whether `user` may change their password without typing the current one.
  #
  # The header has to assert this very user on this very request, so a
  # password-login session never qualifies. The admin can switch the waiver
  # off with trusted_header_auth.password_self_service.
  def password_self_service?(env, user) : Bool
    Invidious::ArikSettings.password_self_service?(
      CONFIG.trusted_header_auth.password_self_service,
      asserted_email(env),
      user.email
    )
  end

  # Return a session id for `email`. Reuses `sid` when that session already
  # belongs to the user; otherwise provisions account + session and sets the
  # SID cookie, mirroring the manual login flow (routes/login.cr).
  def ensure_session(env, sid : String?, email : String) : String
    if sid
      session_email = Invidious::Database::SessionIDs.select_email(sid)
      return sid if session_email == email
      # Identity switch: the cookie belongs to somebody else. Drop it.
      Invidious::Database::SessionIDs.delete(sid: sid) if session_email
    end

    if !Invidious::Database::Users.select(email: email)
      provision_user(email)
    end

    new_sid = Base64.urlsafe_encode(Random::Secure.random_bytes(32))
    Invidious::Database::SessionIDs.insert(new_sid, email, handle_conflicts: true)

    host = env.get("header_x-forwarded-host")
    if alt = CONFIG.alternative_domains.index(host)
      env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.alternative_domains[alt], new_sid)
    else
      env.response.cookies["SID"] = Invidious::User::Cookies.sid(CONFIG.domain, new_sid)
    end

    new_sid
  end

  # Same steps as manual registration (routes/login.cr), with a random
  # password nobody knows. The materialized view is required — without it
  # the subscriptions feed raises. Both statements tolerate a concurrent
  # provision of the same user (parallel first-page requests).
  private def provision_user(email : String)
    random_password = Base64.urlsafe_encode(Random::Secure.random_bytes(32))
    user, _ = create_user("", email, random_password)

    Invidious::Database::Users.insert(user, update_on_conflict: true)

    view_name = "subscriptions_#{sha256(user.email)}"
    PG_DB.exec("CREATE MATERIALIZED VIEW IF NOT EXISTS #{view_name} AS #{MATERIALIZED_VIEW_SQL.call(user.email)}")
  end
end
