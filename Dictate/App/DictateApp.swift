import SwiftUI

@main
struct DictateApp: App {
    var body: some Scene {
        MenuBarExtra("Dictate", systemImage: "mic") {
            Button("Quitter") { NSApplication.shared.terminate(nil) }
        }
    }
}
