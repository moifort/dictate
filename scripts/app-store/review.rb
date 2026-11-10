# Sets the App Review information of the editable macOS version: the contact
# is copied from another app of the account (Shiori), the notes explain how
# Dictate works without Accessibility and Input Monitoring.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/review.rb
require_relative "asc"

NOTES = <<~TEXT.strip
  Dictate is push-to-talk dictation. Hold Option + Space, speak, release: the text is placed on the clipboard, and the user pastes it with Command-V.

  New since the approved 1.2.2: the interface is translated into 25 languages, a second shortcut (Control + Option + Space) can be picked in Settings, emojis can be dictated ("emoji rocket"), and error reports can be turned off in Settings, General.

  As in 1.2.2, the app requests neither Accessibility nor Input Monitoring and does not link those APIs. The shortcut is a Carbon global hot key (RegisterEventHotKey), which reports this one shortcut only, and nothing is pasted or read in other apps.
  Microphone: recorded only while the shortcut is held. It is the only permission requested.

  Audio and text never leave the Mac: transcription runs locally (Parakeet, downloaded once from Hugging Face on first launch, about 600 MB) and the cleanup uses Apple Intelligence on device. No account, no login.

  To test: open Dictate, press Continue on the Microphone step, wait for the model, focus any text field (TextEdit), hold Option + Space, speak a sentence, release, press Command-V.
TEXT

app = ASC.get("/v1/apps?filter[bundleId]=#{ASC::BUNDLE_ID}")["data"].first or abort("No Dictate app")
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
puts "Review information set"
