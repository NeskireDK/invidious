require "../spec_helper"
require "../../src/invidious/arik_feed_kinds"

Spectator.describe Invidious::ArikFeedKinds do
  alias Kinds = Invidious::ArikFeedKinds

  UCID = "UC7qUL2EsTHpNcgsz7woW9Iw"

  describe ".uploads_playlist_id" do
    it "swaps the UC prefix for the kind's prefix" do
      expect(Kinds.uploads_playlist_id(UCID, "video")).to eq("UULF7qUL2EsTHpNcgsz7woW9Iw")
      expect(Kinds.uploads_playlist_id(UCID, "short")).to eq("UUSH7qUL2EsTHpNcgsz7woW9Iw")
      expect(Kinds.uploads_playlist_id(UCID, "live")).to eq("UULV7qUL2EsTHpNcgsz7woW9Iw")
    end

    it "keeps the ID length, so the suffix is never truncated" do
      plid = Kinds.uploads_playlist_id(UCID, "short").not_nil!
      expect(plid.size).to eq(UCID.size + 2)
      expect(plid.ends_with?(UCID[2..])).to be_true
    end

    it "refuses an ID that is not a channel ID" do
      expect(Kinds.uploads_playlist_id("PL7qUL2EsTHpNcgsz7woW9Iw", "short")).to be_nil
      expect(Kinds.uploads_playlist_id("UC", "short")).to be_nil
      expect(Kinds.uploads_playlist_id("UCtooshort", "short")).to be_nil
      expect(Kinds.uploads_playlist_id("UC7qUL2EsTHpNcgsz7woW9I/", "short")).to be_nil
    end

    it "refuses a kind it does not know" do
      expect(Kinds.uploads_playlist_id(UCID, "premiere")).to be_nil
      expect(Kinds.uploads_playlist_id(UCID, "")).to be_nil
    end
  end

  describe ".feed_resource" do
    it "addresses the playlist feed, not the channel feed" do
      expect(Kinds.feed_resource(UCID, "short"))
        .to eq("/feeds/videos.xml?playlist_id=UUSH7qUL2EsTHpNcgsz7woW9Iw")
    end

    it "is nil for an unusable channel or kind" do
      expect(Kinds.feed_resource("nonsense", "short")).to be_nil
      expect(Kinds.feed_resource(UCID, "nonsense")).to be_nil
    end
  end

  describe ".kind_from_probe" do
    let(watch) { "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }

    it "reads YouTube's answer: 200 is a Short" do
      expect(Kinds.kind_from_probe(200, nil, "dQw4w9WgXcQ")).to eq("short")
    end

    it "reads a redirect to the video's own watch page as long-form" do
      expect(Kinds.kind_from_probe(303, watch, "dQw4w9WgXcQ")).to eq("video")
      expect(Kinds.kind_from_probe(301, watch, "dQw4w9WgXcQ")).to eq("video")
      expect(Kinds.kind_from_probe(302, watch, "dQw4w9WgXcQ")).to eq("video")
      expect(Kinds.kind_from_probe(303, "/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ")).to eq("video")
    end

    it "gives no answer for a consent interstitial" do
      consent = "https://consent.youtube.com/m?continue=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ"

      expect(Kinds.kind_from_probe(302, consent, "dQw4w9WgXcQ")).to be_nil
    end

    it "gives no answer for a bot check" do
      sorry = "https://www.google.com/sorry/index?continue=https%3A%2F%2Fwww.youtube.com%2Fshorts%2FdQw4w9WgXcQ"

      expect(Kinds.kind_from_probe(302, sorry, "dQw4w9WgXcQ")).to be_nil
    end

    it "gives no answer for a redirect to a different video" do
      expect(Kinds.kind_from_probe(303, watch, "SomeOtherVid")).to be_nil
    end

    it "gives no answer for a redirect with no destination" do
      expect(Kinds.kind_from_probe(303, nil, "dQw4w9WgXcQ")).to be_nil
      expect(Kinds.kind_from_probe(303, "", "dQw4w9WgXcQ")).to be_nil
      expect(Kinds.kind_from_probe(303, "https://www.youtube.com/watch", "dQw4w9WgXcQ")).to be_nil
    end

    it "gives no answer for a status that carries none" do
      expect(Kinds.kind_from_probe(429, watch, "dQw4w9WgXcQ")).to be_nil
      expect(Kinds.kind_from_probe(500, watch, "dQw4w9WgXcQ")).to be_nil
      expect(Kinds.kind_from_probe(404, watch, "dQw4w9WgXcQ")).to be_nil
    end
  end

  describe ".visible?" do
    it "hides a kind the feed does not admit" do
      expect(Kinds.visible?("short", ["video"])).to be_false
      expect(Kinds.visible?("live", ["video"])).to be_false
      expect(Kinds.visible?("video", ["video"])).to be_true
      expect(Kinds.visible?("live", ["video", "live"])).to be_true
    end

    it "shows an unclassified entry" do
      expect(Kinds.visible?(nil, ["video"])).to be_true
    end

    it "shows an entry whose stored kind is not one we know" do
      expect(Kinds.visible?("premiere", ["video"])).to be_true
    end

    it "shows everything when nothing is configured" do
      expect(Kinds.visible?("short", [] of String)).to be_true
    end
  end

  describe ".json_type" do
    it "reports the kind in the vocabulary clients use for search results" do
      expect(Kinds.json_type("video")).to eq("video")
      expect(Kinds.json_type("short")).to eq("shortVideo")
      expect(Kinds.json_type("live")).to eq("stream")
    end

    it "calls an unclassified entry a video, not a Short" do
      expect(Kinds.json_type(nil)).to eq("video")
      expect(Kinds.json_type("premiere")).to eq("video")
    end
  end

  describe ".clean_kinds" do
    it "accepts the known kinds and fixes their order" do
      cleaned, errors = Kinds.clean_kinds(["live", "video"])
      expect(cleaned).to eq(["video", "live"])
      expect(errors).to be_empty
    end

    it "drops blanks and duplicates, and normalizes case" do
      cleaned, errors = Kinds.clean_kinds(["VIDEO", " video ", "", "  "])
      expect(cleaned).to eq(["video"])
      expect(errors).to be_empty
    end

    it "reports anything that is not a kind" do
      cleaned, errors = Kinds.clean_kinds(["video", "premiere"])
      expect(cleaned).to eq(["video"])
      expect(errors.size).to eq(1)
      expect(errors[0]).to contain("premiere")
    end
  end

  describe ".decode_kinds" do
    it "returns nothing for a missing row, so the config stays authoritative" do
      kinds, error = Kinds.decode_kinds(nil)
      expect(kinds).to be_nil
      expect(error).to be_nil
    end

    it "decodes a stored list" do
      kinds, error = Kinds.decode_kinds(%(["video", "live"]))
      expect(kinds).to eq(["video", "live"])
      expect(error).to be_nil
    end

    it "refuses a malformed row instead of raising" do
      kinds, error = Kinds.decode_kinds(%({"video": true}))
      expect(kinds).to be_nil
      expect(error).not_to be_nil

      kinds, error = Kinds.decode_kinds(%(["premiere"]))
      expect(kinds).to be_nil
      expect(error.not_nil!).to contain("premiere")
    end
  end

  describe ".view_predicate" do
    it "admits NULL alongside the configured kinds" do
      predicate = Kinds.view_predicate(["video"], "cv.kind")
      expect(predicate).to contain("cv.kind IS NULL")
      expect(predicate).to contain("cv.kind IN ('video')")
      expect(predicate).to start_with(" AND (")
    end

    it "lists every configured kind" do
      predicate = Kinds.view_predicate(["video", "live"], "cv.kind")
      expect(predicate).to contain("'video', 'live'")
    end

    it "is empty when the feed admits everything" do
      expect(Kinds.view_predicate([] of String, "cv.kind")).to eq("")
      expect(Kinds.view_predicate(["video", "short", "live"], "cv.kind")).to eq("")
    end

    it "only ever emits the kinds it validated" do
      cleaned, _ = Kinds.clean_kinds(["video'; DROP TABLE users; --"])
      expect(cleaned).to be_empty
      expect(Kinds.view_predicate(cleaned, "cv.kind")).to eq("")
    end
  end
end
