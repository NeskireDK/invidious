require "../spec_helper"

# Which playlists may back a Trending/Popular feed (ArikTube extension).
#
# This existed as a bug first: the feed demanded Public, so setting the lanes
# to unlisted — a perfectly ordinary tidy-up — emptied the instance's front
# page and said so only in a log line nobody was reading. The rule now lives on
# the enum, and this is what holds it there.
Spectator.describe PlaylistPrivacy do
  describe "#feedable?" do
    it "serves a public playlist" do
      expect(PlaylistPrivacy::Public.feedable?).to be_true
    end

    it "serves an unlisted playlist" do
      # Unlisted already means "readable by anyone holding the id", which is
      # exactly what serving it as Popular does.
      expect(PlaylistPrivacy::Unlisted.feedable?).to be_true
    end

    it "refuses a private playlist" do
      expect(PlaylistPrivacy::Private.feedable?).to be_false
    end

    it "answers for every privacy the enum has" do
      # A new member must be considered here rather than defaulting to served.
      expect(PlaylistPrivacy.values.count(&.feedable?)).to eq(2)
    end
  end
end
