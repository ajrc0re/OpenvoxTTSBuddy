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
        .frame(minWidth: 820, minHeight: 520)
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
                    model.text = ""
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
