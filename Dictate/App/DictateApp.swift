import SwiftUI

@main
struct DictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Image(systemName: menuBarSymbol)
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy, value: appDelegate.model.controller.phase)
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }

        Window("Configuration de Dictate", id: "setup") {
            SetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(appDelegate.needsSetup ? .presented : .suppressed)

        Window("Statistiques", id: "stats") {
            StatsView(history: appDelegate.model.history)
        }
        .defaultSize(width: 560, height: 860)
        .defaultLaunchBehavior(.suppressed)

        Window("Mise à jour", id: "update") {
            UpdateView(updater: appDelegate.model.updater)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
    }

    private var menuBarSymbol: String {
        switch appDelegate.model.controller.phase {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .enhancing: "sparkles"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The onboarding opens at every launch until the checklist is complete.
    var needsSetup: Bool {
        !Self.isRunningTests && !model.setup.isComplete
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        model.start()
        if needsSetup { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
