require "../spec_helper"
require "../../src/invidious/arik_header_gate"

# The gate as the running instance calls it: enabled, one trusted proxy, a page
# request from that proxy. An example changes only the thing it is about, so a
# `nil` result always names exactly one refusal.
private module Request
  extend self

  PROXY    = "192.168.1.101"
  OTHER    = "192.168.1.50"
  ASSERTED = ["andre@example.com"]

  def asserted(
    enabled = true,
    path = "/feed/subscriptions",
    header_values : Array(String)? = ASSERTED,
    trusted_proxies = [PROXY],
    peer : String? = PROXY,
  ) : String?
    Invidious::ArikHeaderGate.asserted_email(
      enabled, path, header_values, trusted_proxies, peer)
  end
end

Spectator.describe Invidious::ArikHeaderGate do
  alias Gate = Invidious::ArikHeaderGate
  describe "#normalise_ip" do
    it "reads an IPv4-mapped IPv6 address as the IPv4 address" do
      expect(Gate.normalise_ip("::ffff:192.168.1.101")).to eq("192.168.1.101")
    end

    it "leaves a plain address alone" do
      expect(Gate.normalise_ip("192.168.1.101")).to eq("192.168.1.101")
    end

    it "leaves a real IPv6 address alone" do
      expect(Gate.normalise_ip("2001:db8::1")).to eq("2001:db8::1")
    end
  end

  describe "#trusted_peer?" do
    it "trusts a listed peer" do
      expect(Gate.trusted_peer?([Request::PROXY], Request::PROXY)).to be_true
    end

    it "refuses a peer that is not listed" do
      expect(Gate.trusted_peer?([Request::PROXY], Request::OTHER)).to be_false
    end

    it "trusts nobody when the list is empty" do
      expect(Gate.trusted_peer?(Array(String).new, Request::PROXY)).to be_false
    end

    it "refuses a peer the socket could not name" do
      expect(Gate.trusted_peer?([Request::PROXY], nil)).to be_false
    end

    it "matches an IPv4-mapped peer against a plain listed address" do
      expect(Gate.trusted_peer?([Request::PROXY], "::ffff:#{Request::PROXY}")).to be_true
    end

    it "matches a plain peer against an IPv4-mapped listed address" do
      expect(Gate.trusted_peer?(["::ffff:#{Request::PROXY}"], Request::PROXY)).to be_true
    end

    it "does not match a listed address by prefix" do
      expect(Gate.trusted_peer?(["192.168.1.10"], "192.168.1.101")).to be_false
    end
  end

  describe "#asserted_email" do
    it "believes a single header from a trusted peer" do
      expect(Request.asserted).to eq("andre@example.com")
    end

    it "believes nothing while the extension is off" do
      expect(Request.asserted(enabled: false)).to be_nil
    end

    it "believes nothing from an untrusted peer" do
      expect(Request.asserted(peer: Request::OTHER)).to be_nil
    end

    it "believes nothing when no proxy is trusted" do
      expect(Request.asserted(trusted_proxies: Array(String).new)).to be_nil
    end

    it "believes nothing when the socket could not name the peer" do
      expect(Request.asserted(peer: nil)).to be_nil
    end

    it "ignores the header on an API route, which authenticates by token" do
      expect(Request.asserted(path: "/api/v1/auth/playlists")).to be_nil
    end

    it "ignores the header on every API route, trusted peer or not" do
      expect(Request.asserted(path: "/api/v1/auth/subscriptions", peer: Request::PROXY)).to be_nil
    end

    it "reads a page whose path only starts like an API route" do
      expect(Request.asserted(path: "/apiary")).to eq("andre@example.com")
    end

    it "believes nothing when the header is absent" do
      expect(Request.asserted(header_values: nil)).to be_nil
    end

    it "rejects a duplicated header rather than picking one" do
      expect(Request.asserted(header_values: ["andre@example.com", "admin@example.com"])).to be_nil
    end

    it "rejects a duplicated header even when the two agree" do
      expect(Request.asserted(header_values: ["andre@example.com", "andre@example.com"])).to be_nil
    end

    it "rejects an empty header value" do
      expect(Request.asserted(header_values: [""])).to be_nil
    end

    it "rejects a header of nothing but whitespace" do
      expect(Request.asserted(header_values: ["   "])).to be_nil
    end

    it "rejects an empty header list" do
      expect(Request.asserted(header_values: Array(String).new)).to be_nil
    end

    it "trims the asserted name" do
      expect(Request.asserted(header_values: ["  andre@example.com\t"])).to eq("andre@example.com")
    end

    it "lowercases the asserted name, so one person is one account" do
      expect(Request.asserted(header_values: ["Andre@Example.COM"])).to eq("andre@example.com")
    end

    it "cuts an over-long name to what the email column holds" do
      long = "#{"a" * 300}@example.com"
      expect(Request.asserted(header_values: [long]).try(&.bytesize))
        .to eq(Invidious::ArikHeaderGate::MAX_EMAIL_BYTES)
    end

    it "checks the peer even when the asserted name looks fine" do
      expect(Request.asserted(header_values: ["admin@example.com"], peer: Request::OTHER)).to be_nil
    end
  end
end
