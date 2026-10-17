# Sets the App Review information of the editable macOS version: the contact
# is copied from another app of the account (Shiori), the notes explain the
# permissions Dictate asks for.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/review.rb
require_relative "asc"

NOTES = <<~TEXT.strip
  Dictate is push-to-talk dictation. Hold Control, speak, release: the text appears in the focused field of the frontmost app.

  Input Monitoring: to see the dictation key being held (listen-only event tap, no event is modified or blocked).
  Accessibility: to paste the transcribed text into the focused field of the frontmost app, and to read that field's surrounding text so the on-device model keeps the user's names and tone. Password fields are never read.
  Microphone: recorded only while the key is held.

  Audio and text never leave the Mac: transcription runs locally (Parakeet, downloaded once from Hugging Face on first launch, about 600 MB) and the cleanup uses Apple Intelligence on device. No account, no login.

  To test: open Dictate, grant the three permissions in the setup window, focus any text field (TextEdit), hold Control, speak a sentence, release.
TEXT

app = ASC.get("/v1/apps?filter[bundleId]=com.polyforms.dictate")["data"].first or abort("No Dictate app")
version = ASC.get("/v1/apps/#{app['id']}/appStoreVersions?filter[platform]=MAC_OS")["data"]
  .find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) } or abort("No editable version")

source = ASC.get("/v1/apps?filter[bundleId]=com.polyforms.shiori.app")["data"].first or abort("No Shiori app to copy the contact from")
source_version = ASC.get("/v1/apps/#{source['id']}/appStoreVersions?limit=1")["data"].first
contact = ASC.get("/v1/appStoreVersions/#{source_version['id']}/appStoreReviewDetail")["data"]["attributes"]
  .slice("contactFirstName", "contactLastName", "contactEmail", "contactPhone")

attributes = contact.merge("notes" => NOTES, "demoAccountRequired" => false)
_, existing = ASC.request(:get, "/v1/appStoreVersions/#{version['id']}/appStoreReviewDetail", nil, [404])
if (id = existing.dig("data", "id"))
  ASC.request(:patch, "/v1/appStoreReviewDetails/#{id}", { data: { type: "appStoreReviewDetails", id: id, attributes: attributes } })
else
  ASC.request(:post, "/v1/appStoreReviewDetails", { data: { type: "appStoreReviewDetails", attributes: attributes,
    relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version["id"] } } } } })
end
puts "Review information set (contact #{contact['contactEmail']})"
