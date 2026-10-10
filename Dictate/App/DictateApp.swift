import SwiftUI

@main
struct DictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: appDelegate.model)
        } label: {
            Image(systemName: menuBarSymbol)
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }

        Window("Configuration", id: "setup") {
            SetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(AppDelegate.needsSetup ? .presented : .suppressed)
    }

    private var menuBarSymbol: String {
        switch appDelegate.model.controller.phase {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .processing: "waveform"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var needsSetup: Bool {
        !isRunningTests && (!Permissions.allGranted || !Permissions.fnKeyFree)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        model.start()
        if Self.needsSetup { NSApp.activate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
