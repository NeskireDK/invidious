require "../spec_helper"
require "../parsers_helper"
require "socket"
require "../../src/invidious/yt_backend/socks_proxy"
require "../../src/invidious/yt_backend/connection_pool"

# A keep-alive HTTP server that can answer late, so a spec can walk away from a
# request and then assert what the *next* request on the same pooled socket
# reads back.
class MockCompanion
  LATE_REPLY_DELAY = 0.5.seconds

  @@instances = [] of MockCompanion

  def self.close_all
    @@instances.each(&.close)
    @@instances.clear
  end

  getter port : Int32
  getter connections_accepted : Int32 = 0

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @@instances << self
    spawn run
  end

  def private_url : URI
    URI.parse("http://127.0.0.1:#{@port}")
  end

  def close
    @server.close
  rescue IO::Error
  end

  private def run
    while socket = @server.accept?
      @connections_accepted += 1
      spawn serve(socket)
    end
  rescue IO::Error
  end

  private def serve(socket)
    while request_line = socket.gets
      break if request_line.empty?
      while (header = socket.gets) && !header.empty?
      end
      write_response(socket, request_line)
    end
  rescue IO::Error
  ensure
    socket.close rescue nil
  end

  private def write_response(socket, request_line)
    if request_line.includes?("/late")
      sleep LATE_REPLY_DELAY
      body, content_type = "a segment", "video/mp4"
    else
      body, content_type = "ok", "text/plain"
    end

    socket << "HTTP/1.1 200 OK\r\n"
    socket << "Content-Type: #{content_type}\r\n"
    socket << "Content-Length: #{body.bytesize}\r\n"
    socket << "Connection: keep-alive\r\n\r\n"
    socket << body
    socket.flush
  end
end

Spectator.describe CompanionConnectionPool do
  after_each do
    MockCompanion.close_all
    CONFIG.invidious_companion = [] of Config::CompanionConfig
  end

  # One connection, so every request after the first has to reuse the same socket.
  def pool_for(companion : MockCompanion) : CompanionConnectionPool
    CONFIG.invidious_companion = [
      Config::CompanionConfig.from_yaml("private_url: #{companion.private_url}"),
    ]
    CompanionConnectionPool.new(capacity: 1)
  end

  def get(pool, path) : String
    pool.client do |wrapper|
      wrapper.client.read_timeout = MockCompanion::LATE_REPLY_DELAY * 10
      wrapper.client.get(path) do |response|
        return response.body_io.gets_to_end
      end
    end
    ""
  end

  def walk_away_from_a_late_reply(pool)
    pool.client do |wrapper|
      wrapper.client.read_timeout = MockCompanion::LATE_REPLY_DELAY / 5
      wrapper.client.get("/late") { |response| response.body_io.gets_to_end }
    end
  end

  # The reply lands on the socket after we stopped listening for it. Waiting for
  # it is the whole point: it is what the next request would read.
  def let_the_late_reply_land
    sleep MockCompanion::LATE_REPLY_DELAY * 2
  end

  def abort_mid_response(pool)
    pool.client do |wrapper|
      wrapper.client.get("/healthz") { |response| raise "the player went away" }
    end
  end

  it "reuses a pooled connection when nothing goes wrong" do
    companion = MockCompanion.new
    pool = pool_for(companion)

    expect(get(pool, "/healthz")).to eq("ok")
    expect(get(pool, "/healthz")).to eq("ok")
    expect(companion.connections_accepted).to eq(1)
  end

  # The regression this pool exists to prevent. A request whose response is
  # never read leaves that response queued on the socket, and Crystal keeps the
  # connection alive. Reuse it and the next request reads the previous reply --
  # which is how a healthz probe ends up answering with video/mp4 and DASH
  # playback dies while every healthcheck on the instance stays green.
  it "does not answer the next request with the reply it walked away from" do
    companion = MockCompanion.new
    pool = pool_for(companion)

    expect { walk_away_from_a_late_reply(pool) }.to raise_error(IO::TimeoutError)
    let_the_late_reply_land

    expect(get(pool, "/healthz")).to eq("ok")
  end

  # Replacing the connection rather than discarding it keeps the pool's own
  # bookkeeping straight. Discarding takes a `DB::Pool#release` branch that drops
  # the resource without waking anybody queued on the availability channel, so a
  # fiber waiting on a saturated pool sits out the whole checkout timeout.
  it "keeps its slot in the pool after a request fails" do
    companion = MockCompanion.new
    pool = pool_for(companion)

    expect { walk_away_from_a_late_reply(pool) }.to raise_error(IO::TimeoutError)
    let_the_late_reply_land

    expect(pool.pool.stats.open_connections).to eq(1)
    expect(pool.pool.stats.idle_connections).to eq(1)
  end

  it "serves the next request on a new connection, not the one it walked away from" do
    companion = MockCompanion.new
    pool = pool_for(companion)

    expect { walk_away_from_a_late_reply(pool) }.to raise_error(IO::TimeoutError)
    let_the_late_reply_land
    connections_before = companion.connections_accepted

    expect(get(pool, "/healthz")).to eq("ok")
    expect(companion.connections_accepted).to eq(connections_before + 1)
  end

  it "still answers correctly after a response body was abandoned part-way" do
    companion = MockCompanion.new
    pool = pool_for(companion)

    expect { abort_mid_response(pool) }.to raise_error(/the player went away/)

    expect(get(pool, "/healthz")).to eq("ok")
  end
end
