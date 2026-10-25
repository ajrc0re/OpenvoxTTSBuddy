import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            editorPane
            Divider()
            SettingsPane()
                .frame(width: 340)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have just granted Accessibility access in System Settings.
            model.refreshAccessibilityStatus()
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                if model.text.isEmpty {
                    Text("Paste text here, then press Speak (⌘↩)")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack(spacing: 10) {
                Button {
                    model.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .help("Replace the text with the clipboard. ⇧⌘V pastes and speaks in one go.")

                Button {
                    model.setText("")
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .disabled(model.text.isEmpty)

                StatusLine()
                    .frame(maxWidth: .infinity, alignment: .leading)

                if model.isBusy {
                    Button(role: .cancel) {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop (⌘.)")
                }

                Button {
                    model.speak()
                } label: {
                    Label("Speak", systemImage: "waveform")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .help("Speak (⌘↩)")
                .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }
}

private struct StatusLine: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.isGenerating {
                ProgressView().controlSize(.small)
            } else if model.statusIsError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(model.statusText)
                .lineLimit(2)
                .truncationMode(.tail)
                .foregroundStyle(model.statusIsError ? .primary : .secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Text("\(model.text.count) chars")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .font(.callout)
    }
}

private struct SettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Server") {
                TextField("URL", text: $model.serverURL, prompt: Text(AppModel.defaultServerURL))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.connect() } }
                HStack {
                    ConnectionBadge(state: model.connection)
                    Spacer()
                    Button(model.connection == .connected ? "Refresh" : "Connect") {
                        Task { await model.connect() }
                    }
                    .disabled(model.connection == .connecting)
                }
            }

            Section("Voice") {
                ItemPicker(title: "Model", items: model.models, selection: $model.selectedModel, placeholder: "kokoro")
                HStack {
                    Spacer()
                    if model.isPreloading {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await model.preloadModel() }
                    } label: {
                        Label("Preload model", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.selectedModel.isEmpty || model.isPreloading)
                    .help("Warm the model on the server so the first request is fast")
                }
                ItemPicker(title: "Language", items: model.languages, selection: $model.selectedLanguage, placeholder: "en")
                ItemPicker(title: "Voice", items: model.voices, selection: $model.selectedVoice, placeholder: "af_bella")
            }

            Section("Output") {
                Toggle("Stream audio?", isOn: $model.streamAudio)
                    .help("Start playing as soon as the first audio arrives")

                if model.streamAudio {
                    VolumeSlider(volume: $model.volume)
                } else {
                    Picker("When finished", selection: $model.outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    switch model.outputMode {
                    case .play:
                        PlayerControls(player: model.filePlayer)
                        VolumeSlider(volume: $model.volume)
                    case .save:
                        SaveFolderRow()
                    }
                }

                if model.lastClip != nil {
                    HStack {
                        Spacer()
                        Button("Save last clip…") { model.saveLastClipAs() }
                    }
                }
            }

            Section {
                FilterList()
                Toggle("Show filtered text", isOn: $model.showFiltered)
                    .help("Show the text with matches removed. Turn off to see the original again.")
            } header: {
                Text("Text filters")
            } footer: {
                Text("Matches are removed before speaking. Double-click a pattern to edit it. Add (?i) at the start for case-insensitive matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global hotkeys") {
                Toggle("Paste selection into TTS Buddy", isOn: $model.hotKeyEnabled)
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $model.hotKeyCombo)
                }
                if model.hotKeyConflict {
                    ShortcutConflictLabel()
                }
                Toggle("Paste clipboard into TTS Buddy", isOn: $model.clipboardHotKeyEnabled)
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $model.clipboardHotKeyCombo)
                }
                if model.clipboardHotKeyConflict {
                    ShortcutConflictLabel()
                }
                Picker("Pasted text", selection: $model.hotKeyMode) {
                    ForEach(HotKeyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Speak right away", isOn: $model.hotKeySpeaks)
                if model.hotKeyEnabled && !model.accessibilityTrusted {
                    HStack {
                        Label("Needs Accessibility access to read other apps’ selections.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { SelectionGrabber.openAccessibilitySettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectionBadge: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var color: Color {
        switch state {
        case .unknown: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var label: String {
        switch state {
        case .unknown: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed: return "Unreachable"
        }
    }
}

/// A picker filled from the server, or a text field when the list is empty
/// (not connected yet, or the server returned something unexpected).
private struct ItemPicker: View {
    let title: String
    let items: [OpenVoxItem]
    @Binding var selection: String
    let placeholder: String

    var body: some View {
        if items.isEmpty {
            TextField(title, text: $selection, prompt: Text(placeholder))
        } else {
            Picker(title, selection: $selection) {
                if !items.contains(where: { $0.id == selection }) {
                    Text(selection.isEmpty ? "None" : selection).tag(selection)
                }
                ForEach(items) { item in
                    Text(item.label).tag(item.id)
                }
            }
        }
    }
}

private struct PlayerControls: View {
    @ObservedObject var player: FilePlayer

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .disabled(!player.isLoaded)
            .keyboardShortcut(.space, modifiers: .option)
            .help("Play/Pause (⌥Space)")

            Text(AppModel.formatTime(player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { player.isScrubbing = $0 }
            )
            .disabled(!player.isLoaded)

            Text(AppModel.formatTime(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: $volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Volume")
    }
}

private struct SaveFolderRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Save to")
            HStack {
                Text((model.saveFolder as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(model.saveFolder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { model.chooseSaveFolder() }
                Button {
                    model.revealSaveFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help(model.lastSavedFile == nil ? "Open folder in Finder" : "Show last saved file in Finder")
            }
        }
    }
}

/// The regex list: checkbox to enable, double-click to edit, + and − below.
private struct FilterList: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<TextFilter.ID>()
    @State private var editingID: TextFilter.ID?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: $selection) {
                ForEach($model.filters) { $filter in
                    HStack(spacing: 6) {
                        Toggle("Enabled", isOn: $filter.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        if editingID == filter.id {
                            TextField("Regular expression", text: $draft)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .focused($fieldFocused)
                                .onSubmit { commitEdit() }
                                .onExitCommand { cancelEdit() }
                        } else {
                            Text(filter.pattern.isEmpty ? "Empty pattern" : filter.pattern)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(filter.pattern.isEmpty ? .tertiary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let error = filter.errorMessage {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(error)
                            }
                        }
                    }
                    .tag(filter.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 120)
            .contextMenu(forSelectionType: TextFilter.ID.self) { ids in
                if let id = ids.first, ids.count == 1 {
                    Button("Edit") { beginEdit(id) }
                }
                Button("Delete") { model.removeFilters(ids) }
            } primaryAction: { ids in
                // Double-click
                if let id = ids.first { beginEdit(id) }
            }
            .onDeleteCommand { removeSelected() }
            .onChange(of: fieldFocused) { focused in
                if !focused { commitEdit() }
            }

            HStack(spacing: 2) {
                Button {
                    commitEdit()
                    let id = model.addFilter()
                    selection = [id]
                    beginEdit(id)
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                .help("Add a pattern")
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .disabled(selection.isEmpty)
                .help("Remove the selected patterns")
                Spacer()
            }
            .buttonStyle(.borderless)
        }
    }

    private func beginEdit(_ id: TextFilter.ID) {
        guard let filter = model.filters.first(where: { $0.id == id }) else { return }
        draft = filter.pattern
        editingID = id
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        guard let index = model.filters.firstIndex(where: { $0.id == id }) else { return }
        if draft.isEmpty {
            model.removeFilters([id])
        } else if model.filters[index].pattern != draft {
            model.filters[index].pattern = draft
        }
    }

    private func cancelEdit() {
        guard let id = editingID else { return }
        editingID = nil
        if model.filters.first(where: { $0.id == id })?.pattern.isEmpty == true {
            model.removeFilters([id])
        }
    }

    private func removeSelected() {
        if let editingID, selection.contains(editingID) { self.editingID = nil }
        model.removeFilters(selection)
        selection = []
    }
}

private struct ShortcutConflictLabel: View {
    var body: some View {
        Label("Another app already uses that shortcut. Pick a different one.", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

/// Click, then press a key combination to set a global hotkey.
private struct ShortcutRecorder: View {
    @EnvironmentObject private var model: AppModel
    @Binding var combo: KeyCombo
    @State private var isRecording = false
    @State private var monitor: Any?

    private static let escapeKeyCode: UInt16 = 53

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Type shortcut…" : combo.displayString)
                .frame(minWidth: 100)
        }
        .help("Click, then press a key combination that includes ⌘, ⌃ or ⌥. Esc cancels.")
        .onDisappear { stopRecording() }
        // Hotkeys are switched off while recording, so never leave recording
        // running when the user goes to another app to try the shortcut.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // Let the current combos reach us instead of firing the hotkeys.
        GlobalHotKey.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == Self.escapeKeyCode {
                stopRecording()
            } else if let newCombo = KeyCombo(event: event) {
                stopRecording()
                combo = newCombo
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        model.updateHotKeys(promptForAccess: false)
    }
}
