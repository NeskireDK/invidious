module Invidious::Routes::Companion
  # GET /companion
  def self.get_companion(env)
    url = self.companion_url(env)
    answering_already_started = false

    begin
      COMPANION_POOL.client do |wrapper|
        next if answering_already_started
        wrapper.client.get(url, env.request.headers) do |resp|
          answering_already_started = true
          return self.proxy_companion(env, resp)
        end
      end
    rescue ex
    end
  end

  # POST /companion
  def self.post_companion(env)
    url = self.companion_url(env)
    answering_already_started = false

    begin
      COMPANION_POOL.client do |wrapper|
        next if answering_already_started
        wrapper.client.post(url, env.request.headers, env.request.body) do |resp|
          answering_already_started = true
          return self.proxy_companion(env, resp)
        end
      end
    rescue ex
    end
  end

  def self.options_companion(env)
    url = self.companion_url(env)
    answering_already_started = false

    begin
      COMPANION_POOL.client do |wrapper|
        next if answering_already_started
        wrapper.client.options(url, env.request.headers) do |resp|
          answering_already_started = true
          return self.proxy_companion(env, resp)
        end
      end
    rescue ex
    end
  end

  private def self.companion_url(env) : String
    url = env.request.path
    url += "?#{env.request.query}" if env.request.query
    url
  end

  # Writes companion's reply through to the client.
  #
  # Only ever safe to call once per request: the pool retries its block after a
  # failure, but the status cannot be set again once the reply is underway, and
  # re-asking companion would spend a second upstream fetch on a caller that has
  # usually already gone away.
  private def self.proxy_companion(env, response)
    env.response.status_code = response.status_code
    response.headers.each do |key, value|
      env.response.headers[key] = value
    end

    return IO.copy response.body_io, env.response
  end
end
