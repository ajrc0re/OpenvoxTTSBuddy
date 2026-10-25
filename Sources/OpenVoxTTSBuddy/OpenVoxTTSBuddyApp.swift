import AppKit
import SwiftUI

@main
struct OpenVoxTTSBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest-hotkeys") {
            exit(GlobalHotKey.runSelfTest())
        }
    }

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
        // Keep running in the background while a global hotkey is on, or closing
        // the window would silently turn the hotkeys off.
        let defaults = UserDefaults.standard
        return !(defaults.bool(forKey: "hotKeyEnabled") || defaults.bool(forKey: "clipboardHotKeyEnabled"))
    }
}
