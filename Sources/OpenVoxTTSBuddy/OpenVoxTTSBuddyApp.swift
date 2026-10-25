import AppKit
import SwiftUI

@main
struct OpenVoxTTSBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("OpenVox TTS Buddy", id: "main") {
            ContentView()
                .environmentObject(model)
                .task { await model.connect() }
        }
        .commands {
            CommandMenu("Speech") {
                Button("Speak") { model.speak() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Paste and Speak") {
                    model.pasteFromClipboard()
                    model.speak()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Preload Model") { Task { await model.preloadModel() } }
                Button("Reconnect to Server") { Task { await model.connect() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (`swift run`) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
