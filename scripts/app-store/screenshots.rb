# Uploads the Mac App Store screenshots (docs/app-store-screenshots/<locale>/*.jpg,
# 2880×1800, in name order) to the matching locale of the editable macOS
# version, replacing what is there.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/screenshots.rb
require_relative "asc"
require "digest"

ROOT = File.expand_path("../../docs/app-store-screenshots", __dir__)

app = ASC.get("/v1/apps?filter[bundleId]=com.polyforms.dictate")["data"].first or abort("No Dictate app")
version = ASC.get("/v1/apps/#{app['id']}/appStoreVersions?filter[platform]=MAC_OS")["data"]
  .find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) } or abort("No editable version")

def upload(set_id, path)
  data = File.binread(path)
  _, reserved = ASC.request(:post, "/v1/appScreenshots", { data: { type: "appScreenshots",
    attributes: { fileName: File.basename(path), fileSize: data.bytesize },
    relationships: { appScreenshotSet: { data: { type: "appScreenshotSets", id: set_id } } } } })
  shot = reserved["data"]
  shot["attributes"]["uploadOperations"].each do |op|
    uri = URI(op["url"])
    req = Net::HTTP.const_get(op["method"].capitalize).new(uri)
    op["requestHeaders"].each { |h| req[h["name"]] = h["value"] }
    req.body = data.byteslice(op["offset"], op["length"])
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "upload part failed: HTTP #{res.code}" unless res.code.to_i < 300
  end
  ASC.request(:patch, "/v1/appScreenshots/#{shot['id']}", { data: { type: "appScreenshots", id: shot["id"],
    attributes: { uploaded: true, sourceFileChecksum: Digest::MD5.hexdigest(data) } } })
end

ASC.get("/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations")["data"].each do |loc|
  files = Dir[File.join(ROOT, loc["attributes"]["locale"], "*.jpg")].sort
  next puts("#{loc['attributes']['locale']}: no screenshots, left as is") if files.empty?
  sets = ASC.get("/v1/appStoreVersionLocalizations/#{loc['id']}/appScreenshotSets")["data"]
  set = sets.find { |s| s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP" }
  if set
    ASC.get("/v1/appScreenshotSets/#{set['id']}/appScreenshots")["data"].each { |s| ASC.request(:delete, "/v1/appScreenshots/#{s['id']}") }
  else
    _, created = ASC.request(:post, "/v1/appScreenshotSets", { data: { type: "appScreenshotSets",
      attributes: { screenshotDisplayType: "APP_DESKTOP" },
      relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc["id"] } } } } })
    set = created["data"]
  end
  files.each { |f| upload(set["id"], f) }
  puts "#{loc['attributes']['locale']}: #{files.size} screenshots uploaded"
end
