module Invidious::Routes::Companion
  extend self

  # GET /companion
  def get_companion(env)
    url = make_url(env)
    proxy_companion(env, "GET", url)
  end

  # POST /companion
  def post_companion(env)
    url = make_url(env)
    proxy_companion(env, "POST", url)
  end

  # OPTIONS /companion
  def options_companion(env)
    url = make_url(env)
    proxy_companion(env, "OPTIONS", url)
  end

  private def make_url(env)
    url = env.request.path
    if env.request.query
      url += "?#{env.request.query}"
    end
    url
  end

  # Writes companion's reply through to the client, at most once per request.
  #
  # The pool retries its block after a failure, but once the reply has started
  # the status cannot be set again (and neither can a 502), and re-asking
  # companion would spend a second upstream fetch on a caller that has usually
  # already gone away.
  private def proxy_companion(env, method, url)
    answering_already_started = false

    begin
      COMPANION_POOL.client do |wrapper|
        next if answering_already_started
        wrapper.client.exec(method, url, env.request.headers, (env.request.body if method == "POST")) do |resp|
          answering_already_started = true
          env.response.status_code = resp.status_code
          resp.headers.each do |key, value|
            env.response.headers[key] = value
          end
          return IO.copy resp.body_io, env.response
        end
      end
    rescue
      return if answering_already_started
      env.response.headers.clear
      return Errors.error_json(502, "Couldn't proxy request to Invidious Companion.")
    end
  end
end
