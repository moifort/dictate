# Makes the editable macOS App Store version carry the tag's version number,
# which the uploaded build must match.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/version.rb 0.12.0
require_relative "asc"

marketing = ARGV.fetch(0)
app = ASC.get("/v1/apps?filter[bundleId]=com.polyforms.dictate")["data"].first or abort("No Dictate app in App Store Connect")
versions = ASC.get("/v1/apps/#{app['id']}/appStoreVersions?filter[platform]=MAC_OS")["data"]
if versions.any? { |v| v["attributes"]["versionString"] == marketing }
  puts "App Store version #{marketing} already exists"
  exit
end
editable = versions.find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) }
if editable
  ASC.request(:patch, "/v1/appStoreVersions/#{editable['id']}", { data: { type: "appStoreVersions", id: editable["id"], attributes: { versionString: marketing } } })
  puts "App Store version #{editable['attributes']['versionString']} renamed #{marketing}"
else
  ASC.request(:post, "/v1/appStoreVersions", { data: { type: "appStoreVersions", attributes: { platform: "MAC_OS", versionString: marketing },
    relationships: { app: { data: { type: "apps", id: app["id"] } } } } })
  puts "App Store version #{marketing} created"
end
