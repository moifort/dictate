# Fills the Mac App Store listing of Dictate through the App Store Connect API:
# names, subtitle, description, keywords, URLs, categories, age rating,
# copyright, free price in every territory. Safe to run again: it only
# overwrites what is written here.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ruby scripts/app-store/listing.rb
#
# The App Privacy answers and the screenshots have no public API: they are set
# once in App Store Connect (docs/app-store.md).
require_relative "asc"

BUNDLE_ID = "com.polyforms.dictate"
SITE = "https://moifort.github.io/dictate/"
SUPPORT = "https://github.com/moifort/dictate/issues"

LISTING = {
  "en-US" => {
    name: "Dictate: Speech to Text",
    subtitle: "Push-to-talk dictation",
    keywords: "dictation,voice,speech,transcribe,voice typing,talk,push to talk,offline,notes,writing",
    promotional: "Hold Control, speak, release: clean text appears wherever you type. Free, private, works offline.",
    description: <<~TEXT
      Hold Control, speak, release: your words appear wherever you are typing, clean and ready to send.

      Dictate is push-to-talk dictation for the Mac. It works in every app: Mail, Messages, Notes, Slack, your code editor, the Terminal.

      CLEAN TEXT, NOT A RAW TRANSCRIPT
      Hesitations, repetitions and false starts are removed, punctuation and capitals are fixed, misheard terms are corrected. Your words and meaning stay as you said them.

      ADAPTS TO WHERE YOU ARE
      A bit more polished in an email, direct in a chat, technical in a code editor.

      PRIVATE BY DESIGN
      Speech is transcribed on your Mac, and the cleanup is done by Apple Intelligence on your Mac. Your voice and your text never leave it. No account, no subscription.

      WORKS OFFLINE
      On a plane or a train with no signal, Dictate still writes.

      25 LANGUAGES AND YOUR VOCABULARY
      Pick the dictation language and add your own words: names, jargon, product names.

      DISCREET
      A small pill at the bottom of the screen shows that Dictate is listening, then working, then fades away.

      Requires a Mac with Apple silicon. Free and open source, made by Polyforms.
    TEXT
  },
  "fr-FR" => {
    name: "Dictate : dictée vocale",
    subtitle: "Maintenez, parlez, c'est écrit",
    keywords: "dictée,voix,vocale,transcription,parole,saisie vocale,hors ligne,notes,clavier,écrire",
    promotional: "Maintenez Control, parlez, relâchez : un texte propre apparaît là où vous écrivez. Gratuit, privé, hors ligne.",
    description: <<~TEXT
      Maintenez Control, parlez, relâchez : vos mots apparaissent là où vous écrivez, propres et prêts à envoyer.

      Dictate est une dictée vocale à la demande pour Mac. Elle fonctionne dans toutes les apps : Mail, Messages, Notes, Slack, votre éditeur de code, le Terminal.

      UN TEXTE PROPRE, PAS UNE TRANSCRIPTION BRUTE
      Les hésitations, répétitions et faux départs disparaissent, la ponctuation et les majuscules sont corrigées, les termes mal entendus aussi. Vos mots et votre sens restent les vôtres.

      S'ADAPTE AU CONTEXTE
      Un peu plus soigné dans un mail, direct dans une discussion, technique dans un éditeur de code.

      PRIVÉ PAR CONCEPTION
      La voix est transcrite sur votre Mac, et la relecture est faite par Apple Intelligence sur votre Mac. Votre voix et votre texte n'en sortent jamais. Aucun compte, aucun abonnement.

      FONCTIONNE HORS LIGNE
      Dans un avion ou un train sans réseau, Dictate écrit toujours.

      25 LANGUES ET VOTRE VOCABULAIRE
      Choisissez la langue de dictée et ajoutez vos propres mots : noms, jargon, noms de produits.

      DISCRET
      Une petite pastille en bas de l'écran montre que Dictate écoute, puis travaille, puis s'efface.

      Nécessite un Mac avec puce Apple. Gratuit et open source, conçu par Polyforms.
    TEXT
  }
}.freeze

app = ASC.get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}")["data"].first or abort("No app for #{BUNDLE_ID} in App Store Connect")
app_id = app["id"]
info = ASC.get("/v1/apps/#{app_id}/appInfos")["data"].find { |i| i["attributes"]["state"] != "READY_FOR_DISTRIBUTION" }
version = ASC.get("/v1/apps/#{app_id}/appStoreVersions?filter[platform]=MAC_OS")["data"]
  .find { |v| %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED].include?(v["attributes"]["appStoreState"]) }
abort("No editable macOS version") unless info && version
puts "App #{app_id}, info #{info['id']}, version #{version['attributes']['versionString']} (#{version['id']})"

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
  "ageAssurance" => false, "healthOrWellnessTopics" => false, "parentalControls" => false
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
  version_attributes = { description: text[:description].strip, keywords: text[:keywords], promotionalText: text[:promotional],
                         supportUrl: SUPPORT, marketingUrl: SITE }
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
