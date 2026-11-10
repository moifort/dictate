# Fills the Mac App Store listing of Dictate through the App Store Connect API:
# names, subtitle, description, keywords, what's new, URLs, categories, age
# rating, copyright, free price in every territory, in every locale of
# listing.yml. Safe to run again: it only overwrites what is written here.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/listing.rb
#
# The App Privacy answers and the screenshots have no public API: they are set
# once in App Store Connect (docs/app-store.md).
require_relative "asc"
require "yaml"

BUNDLE_ID = ASC::BUNDLE_ID
SITE = "https://dictate.polyforms.co/"
SUPPORT = "https://github.com/moifort/dictate/issues"

# Texts per App Store locale: listing.yml.
LISTING = YAML.safe_load(File.read(File.join(__dir__, "listing.yml")), symbolize_names: true)
  .to_h { |locale, text| [locale.to_s, text.transform_values(&:strip)] }.freeze
LIMITS = { name: 30, subtitle: 30, keywords: 100, promotional: 170, description: 4000, whats_new: 4000 }.freeze
LISTING.each do |locale, text|
  LIMITS.each do |field, limit|
    length = text.fetch(field).length
    abort("#{locale}: #{field} is #{length} characters, over #{limit}") if length > limit
  end
end

app = ASC.get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}")["data"].first or abort("No app for #{BUNDLE_ID} in App Store Connect")
app_id = app["id"]
info = ASC.get("/v1/apps/#{app_id}/appInfos")["data"].find { |i| i["attributes"]["state"] != "READY_FOR_DISTRIBUTION" }
versions = ASC.get("/v1/apps/#{app_id}/appStoreVersions?filter[platform]=MAC_OS")["data"]
version = versions.find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) }
abort("No editable macOS version") unless info && version
update = versions.any? { |v| v["attributes"]["appStoreState"] == "READY_FOR_SALE" }
puts "App #{app_id}, info #{info['id']}, version #{version['attributes']['versionString']} (#{version['id']})"

# Dictate shows no third-party content: the speech model is not content.
ASC.request(:patch, "/v1/apps/#{app_id}", { data: { type: "apps", id: app_id, attributes: {
  contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT"
} } })

# Categories, then the age rating: nothing in Dictate calls for a rating.
ASC.request(:patch, "/v1/appInfos/#{info['id']}", { data: { type: "appInfos", id: info["id"], relationships: {
  primaryCategory: { data: { type: "appCategories", id: "PRODUCTIVITY" } },
  secondaryCategory: { data: { type: "appCategories", id: "UTILITIES" } }
} } })
rating = ASC.get("/v1/appInfos/#{info['id']}/ageRatingDeclaration")["data"]
none = %w[alcoholTobaccoOrDrugUseOrReferences contests gamblingSimulated horrorOrFearThemes
          matureOrSuggestiveThemes medicalOrTreatmentInformation profanityOrCrudeHumor
          sexualContentGraphicAndNudity sexualContentOrNudity violenceCartoonOrFantasy
          violenceRealistic violenceRealisticProlongedGraphicOrSadistic gunsOrOtherWeapons]
attributes = none.to_h { |k| [k, "NONE"] }.merge(
  "gambling" => false, "lootBox" => false, "unrestrictedWebAccess" => false,
  "messagingAndChat" => false, "userGeneratedContent" => false, "advertising" => false,
  "ageAssurance" => false, "healthOrWellnessTopics" => false, "parentalControls" => false,
  "socialMedia" => false
)
# The declaration grows new questions every year: send only those this one knows.
attributes.select! { |k, _| rating["attributes"].key?(k) }
ASC.request(:patch, "/v1/ageRatingDeclarations/#{rating['id']}", { data: { type: "ageRatingDeclarations", id: rating["id"], attributes: attributes } })
puts "Categories and age rating set"

ASC.request(:patch, "/v1/appStoreVersions/#{version['id']}", { data: { type: "appStoreVersions", id: version["id"], attributes: {
  copyright: "#{Time.now.year} Polyforms"
} } })

info_locs = ASC.get("/v1/appInfos/#{info['id']}/appInfoLocalizations")["data"]
LISTING.each do |locale, text|
  info_attributes = { name: text[:name], subtitle: text[:subtitle], privacyPolicyUrl: "#{SITE}privacy.html" }
  if (existing = info_locs.find { |l| l["attributes"]["locale"] == locale })
    ASC.request(:patch, "/v1/appInfoLocalizations/#{existing['id']}", { data: { type: "appInfoLocalizations", id: existing["id"], attributes: info_attributes } })
  else
    ASC.request(:post, "/v1/appInfoLocalizations", { data: { type: "appInfoLocalizations", attributes: info_attributes.merge(locale: locale),
      relationships: { appInfo: { data: { type: "appInfos", id: info["id"] } } } } })
  end

  # Adding a locale to the app info adds it to the version too: read them now.
  version_locs = ASC.get("/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations")["data"]
  version_attributes = { description: text[:description], keywords: text[:keywords], promotionalText: text[:promotional],
                         supportUrl: SUPPORT, marketingUrl: SITE }
  # The first version of an app has no "What's New": App Store Connect refuses the field.
  version_attributes[:whatsNew] = text[:whats_new] if update
  if (existing = version_locs.find { |l| l["attributes"]["locale"] == locale })
    ASC.request(:patch, "/v1/appStoreVersionLocalizations/#{existing['id']}", { data: { type: "appStoreVersionLocalizations", id: existing["id"], attributes: version_attributes } })
  else
    ASC.request(:post, "/v1/appStoreVersionLocalizations", { data: { type: "appStoreVersionLocalizations", attributes: version_attributes.merge(locale: locale),
      relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version["id"] } } } } })
  end
  puts "Listing #{locale} set"
end

# Free everywhere: the free price point of the base territory, and every
# territory, present and future.
# A new app answers with a schedule id but no prices behind it (404).
_, existing_schedule = ASC.request(:get, "/v1/apps/#{app_id}/appPriceSchedule", nil, [404])
schedule_id = existing_schedule.dig("data", "id")
_, prices = schedule_id ? ASC.request(:get, "/v1/appPriceSchedules/#{schedule_id}/manualPrices", nil, [404]) : [404, {}]
if Array(prices["data"]).empty?
  free = ASC.get("/v1/apps/#{app_id}/appPricePoints?filter[territory]=USA&limit=200")["data"]
    .find { |p| p["attributes"]["customerPrice"].to_f.zero? } or abort("No free price point")
  ASC.request(:post, "/v1/appPriceSchedules", {
    data: { type: "appPriceSchedules", relationships: {
      app: { data: { type: "apps", id: app_id } },
      baseTerritory: { data: { type: "territories", id: "USA" } },
      manualPrices: { data: [{ type: "appPrices", id: "${free}" }] }
    } },
    included: [{ type: "appPrices", id: "${free}", attributes: { startDate: nil },
                 relationships: { appPricePoint: { data: { type: "appPricePoints", id: free["id"] } } } }]
  })
  puts "Price set: free"
else
  puts "Price already set"
end

_, availability = ASC.request(:get, "/v1/apps/#{app_id}/appAvailabilityV2", nil, [404])
if availability.dig("data", "id").nil?
  territories = ASC.get("/v1/territories?limit=200")["data"].map { |t| t["id"] }
  ASC.request(:post, "/v2/appAvailabilities", {
    data: { type: "appAvailabilities", attributes: { availableInNewTerritories: true }, relationships: {
      app: { data: { type: "apps", id: app_id } },
      territoryAvailabilities: { data: territories.map { |t| { type: "territoryAvailabilities", id: "${#{t}}" } } }
    } },
    included: territories.map { |t| { type: "territoryAvailabilities", id: "${#{t}}", attributes: { available: true },
                                      relationships: { territory: { data: { type: "territories", id: t } } } } }
  })
  puts "Available in #{territories.size} territories"
else
  puts "Availability already set"
end
