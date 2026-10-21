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
        .defaultLaunchBehavior(appDelegate.needsSetup || ScreenshotMode.window == "setup" ? .presented : .suppressed)

        Window("Statistiques", id: "stats") {
            StatsView(history: appDelegate.model.history)
                .modifier(ScreenshotSettingsOpener())
        }
        .defaultSize(width: 560, height: 860)
        .defaultLaunchBehavior(["stats", "settings"].contains(ScreenshotMode.window) ? .presented : .suppressed)

        #if !APP_STORE
        Window("Mise à jour", id: "update") {
            UpdateView(updater: appDelegate.model.updater)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        #endif
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
    let model: AppModel

    override init() {
        // Before the model: its setup already touches the microphone and the models.
        ErrorReporter.start()
        model = AppModel()
        super.init()
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The onboarding opens at every launch until dictation can work.
    var needsSetup: Bool {
        !Self.isRunningTests && model.setup.needsOnboarding
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        model.start()
        if needsSetup { NSApp.activate() }
        // Active, so the window is drawn as the front one.
        if ScreenshotMode.window != nil { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
