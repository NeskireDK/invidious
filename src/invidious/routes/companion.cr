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

  private def proxy_companion(env, method, url)
    relay(COMPANION_POOL, env, method, url)
  end

  # Writes companion's reply through to the client, at most once per request.
  # A reply that breaks after it started raises, so the client gets a clean 500 or a dropped connection, never a hang.
  def relay(pool : CompanionConnectionPool, env, method, url)
    answering_already_started = false

    begin
      pool.client do |wrapper|
        next if answering_already_started
        wrapper.client.exec(method, url, env.request.headers, (env.request.body if method == "POST")) do |resp|
          answering_already_started = true
          env.response.status_code = resp.status_code
          resp.headers.each do |key, value|
            env.response.headers[key] = value
          end
          bytes_relayed = IO.copy resp.body_io, env.response
          raise BrokenCompanionReply.new unless all_promised_bytes_arrived?(resp, bytes_relayed)
          return bytes_relayed
        end
      end
    rescue
      return answer_bad_gateway(env) unless answering_already_started
    end

    env.response.headers.clear
    raise BrokenCompanionReply.new
  end

  private def all_promised_bytes_arrived?(resp, bytes_relayed) : Bool
    return true if resp.status.no_content? || resp.status.not_modified?
    promised_bytes = resp.headers["Content-Length"]?.try(&.to_i64?)
    promised_bytes.nil? || bytes_relayed >= promised_bytes
  end

  private def answer_bad_gateway(env)
    env.response.headers.clear
    Errors.error_json(502, "Couldn't proxy request to Invidious Companion.")
  end

  class BrokenCompanionReply < IO::Error
    def initialize
      super("Companion's reply broke off after its headers were sent")
    end
  end
end
