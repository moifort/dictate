import SwiftUI

/// Picks the dictation language; shared by the onboarding and the settings.
struct LanguagePicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("Langue", selection: Bindable(model.settings).language) {
            ForEach(DictationLanguage.pickerCodes, id: \.self) { code in
                Text(DictationLanguage.name(of: code).localizedCapitalized).tag(code)
            }
        }
        // The Claude prompt names the language: the waiting process is stale.
        .onChange(of: model.settings.language) { model.settingsChanged() }
    }
}
