# The trusted-header decision, without the request or the configuration
# (ArikTube extension).
#
# `TrustedHeaderAuth` reads `env` and `CONFIG` and passes the values in here.
# Everything this module refuses is a request that would otherwise have
# authenticated as somebody else, including the admin, so it is the part of the
# extension most worth pinning — and it cannot be pinned while it reads two
# globals a spec has no way to build.
#
# Pure module. `TrustedHeaderAuth` does the IO.
module Invidious::ArikHeaderGate
  extend self

  # `users.email` is 254 bytes wide; anything longer is not an address.
  MAX_EMAIL_BYTES = 254

  # "::ffff:192.168.1.101" and "192.168.1.101" are the same peer
  def normalise_ip(address : String) : String
    address.lchop("::ffff:")
  end

  # Whether the TCP peer is one of the proxies the admin listed. Never
  # X-Forwarded-For: a client can write that header itself.
  def trusted_peer?(trusted_proxies : Array(String), peer : String?) : Bool
    return false if peer.nil?

    address = normalise_ip(peer)
    trusted_proxies.any? { |trusted| normalise_ip(trusted) == address }
  end

  # The user name the proxy asserted, or nil when the assertion may not be
  # believed. An empty `trusted_proxies` therefore trusts nobody.
  def asserted_email(
    enabled : Bool,
    path : String,
    header_values : Array(String)?,
    trusted_proxies : Array(String),
    peer : String?,
  ) : String?
    return nil if !enabled

    # API clients (Yattee, bots) authenticate with tokens only
    return nil if path.starts_with?("/api/")

    return nil if header_values.nil?
    # A duplicated header is an attack indicator: reject the request
    return nil if header_values.size != 1

    email = header_values[0].strip.downcase.byte_slice(0, MAX_EMAIL_BYTES)
    return nil if email.empty?
    return nil if !trusted_peer?(trusted_proxies, peer)

    email
  end
end
