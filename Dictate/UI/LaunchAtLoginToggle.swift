import AppKit
import ServiceManagement
import SwiftUI

/// The login item lives in macOS, not in the settings, and registration can
/// be refused: the toggle shows what macOS actually did. Shared by the
/// onboarding and the settings so that both places agree.
///
/// Once the user has turned Dictate off in System Settings, macOS keeps it
/// waiting for their approval there: the toggle stays off and says where to go.
struct LaunchAtLoginToggle: View {
    let title: LocalizedStringKey
    let settings: AppSettings
    @State private var enabled = false
    @State private var needsApproval = false

    init(_ title: LocalizedStringKey = "Ouvrir à l'ouverture de session", settings: AppSettings) {
        self.title = title
        self.settings = settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $enabled)
                .onChange(of: enabled) {
                    // Reading the state back also fires this: only act on a real change.
                    guard enabled != settings.launchAtLogin else { return }
                    settings.launchAtLogin = enabled
                    refresh()
                }

            if needsApproval {
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS attend votre accord dans Réglages Système.")
                        .foregroundStyle(.secondary)
                    Button("Ouvrir les éléments de connexion…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .buttonStyle(.link)
                }
                .font(.caption)
            }
        }
        .animation(.snappy, value: needsApproval)
        .onAppear(perform: refresh)
        // The user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        enabled = settings.launchAtLogin
        needsApproval = settings.launchAtLoginNeedsApproval
    }
}
