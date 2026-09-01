require "json"
require "uri"

# Content kinds for subscription feed entries (ArikTube extension).
#
# Upstream has no usable signal: `ChannelVideo#to_json` reports
# `"type": "shortVideo"` for every row, and `channel_videos.length_seconds` is
# 0 for anything absent from the channel's Videos tab — Shorts and stream VODs
# alike. YouTube's per-channel uploads playlists supply it instead, addressed
# by replacing the "UC" of the channel ID: UULF long-form, UUSH Shorts, UULV
# live. Measured over 75 channels: 1 Short leaked into a UULF feed out of 679.
#
# Pure module. `Jobs::ClassifyChannelVideosJob` does the IO.
module Invidious::ArikFeedKinds
  extend self

  KIND_VIDEO = "video"
  KIND_SHORT = "short"
  KIND_LIVE  = "live"

  KINDS = [KIND_VIDEO, KIND_SHORT, KIND_LIVE]

  PLAYLIST_PREFIX = {
    KIND_VIDEO => "UULF",
    KIND_SHORT => "UUSH",
    KIND_LIVE  => "UULV",
  }

  # Validated, not assumed: a malformed ID would become a playlist ID that
  # returns somebody else's feed.
  UCID_REGEX = /\AUC[A-Za-z0-9_-]{22}\z/

  def uploads_playlist_id(ucid : String, kind : String) : String?
    return nil if !UCID_REGEX.matches?(ucid)

    prefix = PLAYLIST_PREFIX[kind]?
    return nil if prefix.nil?

    "#{prefix}#{ucid[2..]}"
  end

  def feed_resource(ucid : String, kind : String) : String?
    plid = uploads_playlist_id(ucid, kind)
    return nil if plid.nil?

    "/feeds/videos.xml?playlist_id=#{plid}"
  end

  def shorts_probe_resource(id : String) : String
    "/shorts/#{id}"
  end

  REDIRECT_STATUSES = [301, 302, 303, 307, 308]

  # YouTube answers 200 for a Short and redirects anything else to that video's
  # watch page. A status that says nothing leaves the row unclassified rather
  # than guessing.
  #
  # The destination is checked, not just the status: a consent interstitial, a
  # /sorry/ bot check and a geo redirect are all 3xx too, and reading those as
  # a positive answer would relabel the whole backlog at PROBES_PER_TICK rows
  # a tick.
  def kind_from_probe(status : Int32, location : String?, id : String) : String?
    return KIND_SHORT if status == 200
    return nil if !REDIRECT_STATUSES.includes?(status)
    return nil if location.nil?

    watch_redirect?(location, id) ? KIND_VIDEO : nil
  end

  # Whether `location` is this very video's watch page.
  private def watch_redirect?(location : String, id : String) : Bool
    uri = URI.parse(location)
    return false if uri.path != "/watch"

    uri.query_params["v"]? == id
  rescue
    false
  end

  def known?(kind : String?) : Bool
    !kind.nil? && KINDS.includes?(kind)
  end

  def json_type(kind : String?) : String
    case kind
    when KIND_SHORT then "shortVideo"
    when KIND_LIVE  then "stream"
    else                 "video"
    end
  end

  # Fail-open: an unclassified row is shown, and an empty `allowed` shows
  # everything. A late or broken classifier must never blank a feed.
  def visible?(kind : String?, allowed : Array(String)) : Bool
    return true if allowed.empty?
    return true if !known?(kind)

    allowed.includes?(kind)
  end

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

  # Never raises: one bad row must not stop the instance from booting.
  def decode_kinds(raw : String?) : {Array(String)?, String?}
    return {nil, nil} if raw.nil?

    kinds = Array(String).from_json(raw)
    cleaned, errors = clean_kinds(kinds)
    return {nil, errors.join("; ")} if !errors.empty?

    {cleaned, nil}
  rescue ex
    {nil, "not a JSON list of content kinds (#{ex.message})"}
  end

  # `IS NULL` is inside the predicate so the fail-open rule holds within the
  # materialized view too. Only ever receives `clean_kinds` output.
  def view_predicate(allowed : Array(String), column : String = "kind") : String
    return "" if allowed.empty?
    return "" if KINDS.all? { |kind| allowed.includes?(kind) }

    list = allowed.map { |kind| "'#{kind}'" }.join(", ")
    " AND (#{column} IS NULL OR #{column} IN (#{list}))"
  end
end
