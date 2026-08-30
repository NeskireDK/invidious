require "json"

# Content kinds for subscription feed entries (ArikTube extension).
#
# Upstream Invidious does not record what *sort* of thing a subscription feed
# entry is. `ChannelVideo#to_json` reports `"type": "shortVideo"` for every
# row — that string is legacy naming for "abbreviated video object" and says
# nothing about Shorts — and the real `VideoType` enum
# (`Video`/`Livestream`/`Scheduled`) exists only on the full watch-page
# object, never on a listing. So a client cannot tell a Short from a
# long-form upload, and neither can a feed query.
#
# The missing signal is available for free. YouTube publishes a per-channel
# uploads playlist per content kind, addressed by replacing the "UC" of the
# channel ID with a prefix, and `/feeds/videos.xml?playlist_id=` serves each
# one as RSS:
#
#   UULF…  long-form uploads
#   UUSH…  Shorts
#   UULV…  live streams
#
# Measured over 75 subscribed channels (15 newest entries each): 1114
# long-form, 679 Shorts, 299 live, and exactly **one** Short leaking into a
# UULF feed. `UULF ∩ UULV` was empty. That is YouTube's own classification,
# so it beats any length heuristic — a 27-second detailing clip and an
# 18199-second stream VOD both land in `channel_videos` with
# `length_seconds = 0`, which is why length cannot be used here.
#
# This module is pure: prefix arithmetic, validation and visibility rules,
# no database and no HTTP. `Jobs::ClassifyChannelVideosJob` does the IO.
module Invidious::ArikFeedKinds
  extend self

  KIND_VIDEO = "video"
  KIND_SHORT = "short"
  KIND_LIVE  = "live"

  # Every kind a row may be labelled with, in the order the settings page
  # lists them.
  KINDS = [KIND_VIDEO, KIND_SHORT, KIND_LIVE]

  # The uploads-playlist prefix that replaces "UC" in a channel ID.
  PLAYLIST_PREFIX = {
    KIND_VIDEO => "UULF",
    KIND_SHORT => "UUSH",
    KIND_LIVE  => "UULV",
  }

  # A channel ID is "UC" plus 22 characters. Checked rather than assumed: a
  # malformed ID would otherwise be turned into a playlist ID that quietly
  # returns somebody else's feed.
  UCID_REGEX = /\AUC[A-Za-z0-9_-]{22}\z/

  # ------------------------------------------------------------------
  #  Playlist / feed addressing
  # ------------------------------------------------------------------

  # The uploads playlist of `ucid` holding only videos of `kind`, or nil when
  # either argument is not one this module knows.
  def uploads_playlist_id(ucid : String, kind : String) : String?
    return nil if !UCID_REGEX.matches?(ucid)

    prefix = PLAYLIST_PREFIX[kind]?
    return nil if prefix.nil?

    "#{prefix}#{ucid[2..]}"
  end

  # The RSS resource (path and query, no host) listing the newest entries of
  # `kind` for `ucid`.
  #
  # Note this is the *playlist* feed, not the channel feed upstream uses.
  # The two carry the same per-entry fields, but the feed-level <title> of a
  # playlist feed is the playlist's name ("Videos", "Short videos", "Live
  # streams") rather than the channel's — which is exactly why
  # `fetch_channel` is left alone: it reads that title as the channel author.
  def feed_resource(ucid : String, kind : String) : String?
    plid = uploads_playlist_id(ucid, kind)
    return nil if plid.nil?

    "/feeds/videos.xml?playlist_id=#{plid}"
  end

  # The path whose response status tells us whether `id` is a Short.
  #
  # YouTube answers 200 for a Short and 303 (redirect to /watch) for anything
  # else. Verified identical for HEAD and GET, so the probe costs no body.
  # This is the fallback for rows too old to still sit in a 15-entry feed
  # window; it is authoritative, but it only answers short/not-short.
  def shorts_probe_resource(id : String) : String
    "/shorts/#{id}"
  end

  # The kind implied by a `/shorts/<id>` probe status, or nil when the status
  # says nothing (a 5xx, a rate limit, a network hiccup). Nil must leave the
  # row unclassified rather than guess.
  def kind_from_probe_status(status : Int32) : String?
    case status
    when 200                     then KIND_SHORT
    when 301, 302, 303, 307, 308 then KIND_VIDEO
    else                              nil
    end
  end

  # ------------------------------------------------------------------
  #  Visibility
  # ------------------------------------------------------------------

  def known?(kind : String?) : Bool
    !kind.nil? && KINDS.includes?(kind)
  end

  # The `type` a listing entry reports to clients, in the vocabulary they
  # already use for search results.
  #
  # An unclassified row reports "video", not "shortVideo": the same fail-open
  # rule as `visible?`. A client filtering on `type == "shortVideo"` must not
  # hide a long-form upload just because the classifier has not reached it.
  def json_type(kind : String?) : String
    case kind
    when KIND_SHORT then "shortVideo"
    when KIND_LIVE  then "stream"
    else                 "video"
    end
  end

  # Whether a row of `kind` belongs in a feed that admits `allowed`.
  #
  # **Fail-open on purpose.** An unclassified row is shown. The classifier
  # runs on a timer, so a brand-new upload is unlabelled for up to one
  # interval; hiding it instead would mean a late or broken job silently
  # empties the subscription feed, which is far worse than a Short slipping
  # through for a few minutes. An empty `allowed` list also shows everything,
  # so a misconfiguration cannot blank the feed either.
  def visible?(kind : String?, allowed : Array(String)) : Bool
    return true if allowed.empty?
    return true if !known?(kind)

    allowed.includes?(kind)
  end

  # Cleans a submitted kind list: unknown entries refused, order fixed to
  # `KINDS`, duplicates dropped. Returns the cleaned list and a message per
  # entry refused.
  def clean_kinds(entries : Array(String)) : {Array(String), Array(String)}
    cleaned = [] of String
    errors = [] of String

    entries.each do |entry|
      kind = entry.strip.downcase
      next if kind.empty?

      if !KINDS.includes?(kind)
        errors << "'#{kind}' is not a content kind (#{KINDS.join(", ")})"
        next
      end

      cleaned << kind if !cleaned.includes?(kind)
    end

    {KINDS.select { |kind| cleaned.includes?(kind) }, errors}
  end

  # Decodes a stored kind list. Returns the list and nil, or nil and the
  # reason the row was ignored — an exception never leaves here, because one
  # bad row must not stop the instance from booting.
  def decode_kinds(raw : String?) : {Array(String)?, String?}
    return {nil, nil} if raw.nil?

    kinds = Array(String).from_json(raw)
    cleaned, errors = clean_kinds(kinds)
    return {nil, errors.join("; ")} if !errors.empty?

    {cleaned, nil}
  rescue ex
    {nil, "not a JSON list of content kinds (#{ex.message})"}
  end

  # ------------------------------------------------------------------
  #  Feed SQL
  # ------------------------------------------------------------------

  # The predicate that restricts a subscription feed to `allowed`, or an
  # empty string when it admits everything.
  #
  # `kind IS NULL` is part of the predicate rather than handled outside it:
  # the fail-open rule has to hold inside the materialized view too, or a
  # row would be invisible until the classifier reaches it.
  def view_predicate(allowed : Array(String), column : String = "kind") : String
    return "" if allowed.empty?
    return "" if KINDS.all? { |kind| allowed.includes?(kind) }

    list = allowed.map { |kind| "'#{kind}'" }.join(", ")
    " AND (#{column} IS NULL OR #{column} IN (#{list}))"
  end
end
