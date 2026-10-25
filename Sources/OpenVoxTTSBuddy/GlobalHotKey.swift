import AppKit
import Carbon.HIToolbox

/// A key combination stored as a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// The key's character as typed, for display (e.g. "T").
    var keyLabel: String

    /// ⌃⌥T
    static let defaultCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_T),
                                       carbonModifiers: UInt32(controlKey | optionKey),
                                       keyLabel: "T")

    /// ⌃⌥V
    static let defaultClipboardCombo = KeyCombo(keyCode: UInt32(kVK_ANSI_V),
                                                carbonModifiers: UInt32(controlKey | optionKey),
                                                keyLabel: "V")

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    /// Builds a combo from a key press; nil unless it includes ⌘, ⌃ or ⌥.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
        self.keyLabel = Self.label(for: event)
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            if let number = functionKeyNumbers[Int(event.keyCode)] { return "F\(number)" }
            let chars = event.charactersIgnoringModifiers ?? ""
            return chars.isEmpty ? "Key \(event.keyCode)" : chars.uppercased()
        }
    }

    private static let functionKeyNumbers: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8,
        kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
        kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]
}

/// What a global hot key does.
enum HotKeyAction: UInt32, CaseIterable {
    case pasteSelection = 1
    case pasteClipboard = 2
}

/// Registers system-wide hot keys with Carbon's RegisterEventHotKey.
/// Registering doesn't need any permission; reading another app's selection does.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPress: ((HotKeyAction) -> Void)?

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4F56_5442 // "OVTB"

    private init() {}

    /// Returns false if the combo is already taken by another app.
    @discardableResult
    func register(_ combo: KeyCombo, for action: HotKeyAction) -> Bool {
        unregister(action)
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("OpenVox TTS Buddy: RegisterEventHotKey(%@) failed with %d", combo.displayString, status)
            return false
        }
        hotKeyRefs[action] = ref
        return true
    }

    func isRegistered(_ action: HotKeyAction) -> Bool {
        hotKeyRefs[action] != nil
    }

    func unregister(_ action: HotKeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    func unregisterAll() {
        HotKeyAction.allCases.forEach(unregister)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let action = HotKeyAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { GlobalHotKey.shared.onPress?(action) }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    /// Delivers a hot key event through the same Carbon handler a real key press uses.
    private func simulatePress(_ action: HotKeyAction) -> OSStatus {
        var event: EventRef?
        var status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                                 EventAttributes(kEventAttributeNone), &event)
        guard status == noErr, let event else { return status }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: signature, id: action.rawValue)
        status = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   MemoryLayout<EventHotKeyID>.size, &id)
        guard status == noErr else { return status }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    /// `OpenVoxTTSBuddy --selftest-hotkeys`: registers every hot key, fires each
    /// one through the Carbon handler and checks the right action arrives. Used by CI.
    static func runSelfTest() -> Int32 {
        _ = NSApplication.shared
        let hotKeys = GlobalHotKey.shared
        var fired: [HotKeyAction] = []
        hotKeys.onPress = { fired.append($0) }

        // Unusual combos so the test doesn't collide with anything on the runner.
        let combos: [HotKeyAction: KeyCombo] = [
            .pasteSelection: KeyCombo(keyCode: UInt32(kVK_F17), carbonModifiers: UInt32(controlKey | optionKey | shiftKey), keyLabel: "F17"),
            .pasteClipboard: KeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey), keyLabel: "F18"),
        ]
        var ok = true
        for action in HotKeyAction.allCases {
            let registered = hotKeys.register(combos[action]!, for: action)
            print("register \(action): \(registered ? "ok" : "FAILED")")
            ok = ok && registered
        }
        for action in HotKeyAction.allCases {
            let status = hotKeys.simulatePress(action)
            print("send \(action): status \(status)")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        print("fired: \(fired)")
        ok = ok && fired == HotKeyAction.allCases
        hotKeys.unregisterAll()
        print(ok ? "HOTKEY SELFTEST PASSED" : "HOTKEY SELFTEST FAILED")
        return ok ? 0 : 1
    }
}

/// Grabs the text currently selected in the frontmost app.
@MainActor
enum SelectionGrabber {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Accessibility settings.
    @discardableResult
    static func requestAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Tries the Accessibility API first, then falls back to sending ⌘C and
    /// reading the clipboard (restoring what was on it afterwards).
    static func selectedText() async -> String? {
        if let text = accessibilitySelection(), !text.isEmpty { return text }
        return await copySelection()
    }

    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        // The hot key fires while its modifiers are still held; wait briefly for
        // them to be released so the target app sees a clean ⌘C.
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        for _ in 0..<10 where !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC = CGKeyCode(kVK_ANSI_C)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the frontmost app up to half a second to put the selection on the clipboard.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != before { break }
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        restore(saved, to: pasteboard)
        return text
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
