# Attaches the uploaded build to the macOS App Store version and submits it
# for review, released automatically once approved.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/submit.rb 1.0.0 245
require_relative "asc"

marketing, build_number = ARGV.fetch(0), ARGV.fetch(1)
app = ASC.get("/v1/apps?filter[bundleId]=com.polyforms.dictate")["data"].first or abort("No Dictate app")
version = ASC.get("/v1/apps/#{app['id']}/appStoreVersions?filter[platform]=MAC_OS&filter[versionString]=#{marketing}")["data"].first or abort("No App Store version #{marketing}")

# App Store Connect takes several minutes to process an upload.
build = nil
60.times do
  build = ASC.get("/v1/builds?filter[app]=#{app['id']}&filter[version]=#{build_number}&filter[preReleaseVersion.version]=#{marketing}")["data"].first
  state = build&.dig("attributes", "processingState")
  break if state == "VALID"
  abort("Build #{build_number} is #{state}") if %w[FAILED INVALID].include?(state)
  puts "Build #{build_number}: #{state || 'not there yet'}, waiting 60 s…"
  sleep 60
end
abort("Build #{build_number} never became valid") unless build&.dig("attributes", "processingState") == "VALID"

ASC.request(:patch, "/v1/appStoreVersions/#{version['id']}", { data: { type: "appStoreVersions", id: version["id"],
  attributes: { releaseType: "AFTER_APPROVAL" },
  relationships: { build: { data: { type: "builds", id: build["id"] } } } } })
puts "Build #{build_number} attached to #{marketing}"

# Reuse a submission left open by an earlier, refused attempt.
open_submission = ASC.get("/v1/reviewSubmissions?filter[app]=#{app['id']}&filter[platform]=MAC_OS&filter[state]=READY_FOR_REVIEW")["data"].first
if open_submission
  submission_id = open_submission["id"]
else
  _, submission = ASC.request(:post, "/v1/reviewSubmissions", { data: { type: "reviewSubmissions",
    attributes: { platform: "MAC_OS" }, relationships: { app: { data: { type: "apps", id: app["id"] } } } } })
  submission_id = submission["data"]["id"]
end
items = ASC.get("/v1/reviewSubmissions/#{submission_id}/items")["data"]
if items.empty?
  ASC.request(:post, "/v1/reviewSubmissionItems", { data: { type: "reviewSubmissionItems",
    relationships: { reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
                     appStoreVersion: { data: { type: "appStoreVersions", id: version["id"] } } } } })
end
ASC.request(:patch, "/v1/reviewSubmissions/#{submission_id}", { data: { type: "reviewSubmissions", id: submission_id, attributes: { submitted: true } } })
puts "Dictate #{marketing} (#{build_number}) submitted for review"
