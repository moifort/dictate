import SwiftUI

/// The login item lives in macOS, not in the settings, and registration can
/// be refused: the toggle shows what macOS actually did. Shared by the
/// onboarding and the settings so that both places agree.
struct LaunchAtLoginToggle: View {
    let title: LocalizedStringKey
    let settings: AppSettings
    @State private var enabled = false

    init(_ title: LocalizedStringKey = "Ouvrir à l'ouverture de session", settings: AppSettings) {
        self.title = title
        self.settings = settings
    }

    var body: some View {
        Toggle(title, isOn: $enabled)
            .onChange(of: enabled) {
                settings.launchAtLogin = enabled
                enabled = settings.launchAtLogin
            }
            .onAppear { enabled = settings.launchAtLogin }
    }
}
