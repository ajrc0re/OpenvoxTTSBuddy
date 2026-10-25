import AppKit
import Foundation
import UniformTypeIdentifiers

enum OutputMode: String, CaseIterable, Identifiable {
    case play
    case save

    var id: String { rawValue }
    var title: String { self == .play ? "Play" : "Save" }
}

enum HotKeyMode: String, CaseIterable, Identifiable {
    case replace
    case append

    var id: String { rawValue }
    var title: String { self == .replace ? "Replace" : "Append" }
}

enum ConnectionState {
    case unknown, connecting, connected, failed
}

@MainActor
final class AppModel: ObservableObject {
    private enum Key {
        static let serverURL = "serverURL"
        static let model = "model"
        static let language = "language"
        static let voice = "voice"
        static let stream = "streamAudio"
        static let outputMode = "outputMode"
        static let saveFolder = "saveFolder"
        static let volume = "volume"
        static let filters = "textFilters"
        static let showFiltered = "showFilteredText"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let hotKeyCombo = "hotKeyCombo"
        static let hotKeyMode = "hotKeyMode"
        static let hotKeySpeaks = "hotKeySpeaks"
        static let clipboardHotKeyEnabled = "clipboardHotKeyEnabled"
        static let clipboardHotKeyCombo = "clipboardHotKeyCombo"
    }

    static let defaultServerURL = "http://192.168.1.3:18778"

    private let defaults = UserDefaults.standard

    // MARK: Settings

    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL) }
    }
    @Published var selectedModel: String {
        didSet {
            defaults.set(selectedModel, forKey: Key.model)
            reloadLanguages()
        }
    }
    @Published var selectedLanguage: String {
        didSet {
            defaults.set(selectedLanguage, forKey: Key.language)
            reloadVoices()
        }
    }
    @Published var selectedVoice: String {
        didSet { defaults.set(selectedVoice, forKey: Key.voice) }
    }
    @Published var streamAudio: Bool {
        didSet { defaults.set(streamAudio, forKey: Key.stream) }
    }
    @Published var outputMode: OutputMode {
        didSet { defaults.set(outputMode.rawValue, forKey: Key.outputMode) }
    }
    @Published var saveFolder: String {
        didSet { defaults.set(saveFolder, forKey: Key.saveFolder) }
    }
    @Published var volume: Double {
        didSet {
            defaults.set(volume, forKey: Key.volume)
            filePlayer.volume = Float(volume)
            streamPlayer.volume = Float(volume)
        }
    }

    // MARK: Text filters

    @Published var filters: [TextFilter] {
        didSet {
            defaults.set(try? JSONEncoder().encode(filters), forKey: Key.filters)
            refilterIfShowing()
        }
    }
    /// Shows the filtered text in the editor. Turning it off restores the
    /// original, unless the filtered text was edited in the meantime.
    @Published var showFiltered: Bool {
        didSet {
            defaults.set(showFiltered, forKey: Key.showFiltered)
            guard showFiltered != oldValue else { return }
            if showFiltered { showFilteredText() } else { restoreUnfilteredText() }
        }
    }
    private var unfilteredText: String?
    private var lastFilteredText: String?

    // MARK: Global hot key

    @Published var hotKeyEnabled: Bool {
        didSet {
            defaults.set(hotKeyEnabled, forKey: Key.hotKeyEnabled)
            updateHotKeys(promptForAccess: hotKeyEnabled && !oldValue)
        }
    }
    @Published var hotKeyCombo: KeyCombo {
        didSet {
            defaults.set(try? JSONEncoder().encode(hotKeyCombo), forKey: Key.hotKeyCombo)
            updateHotKeys(promptForAccess: false)
        }
    }
    /// A second hotkey that pastes the clipboard; needs no Accessibility access.
    @Published var clipboardHotKeyEnabled: Bool {
        didSet {
            defaults.set(clipboardHotKeyEnabled, forKey: Key.clipboardHotKeyEnabled)
            updateHotKeys(promptForAccess: false)
        }
    }
    @Published var clipboardHotKeyCombo: KeyCombo {
        didSet {
            defaults.set(try? JSONEncoder().encode(clipboardHotKeyCombo), forKey: Key.clipboardHotKeyCombo)
            updateHotKeys(promptForAccess: false)
        }
    }
    @Published var hotKeyMode: HotKeyMode {
        didSet { defaults.set(hotKeyMode.rawValue, forKey: Key.hotKeyMode) }
    }
    @Published var hotKeySpeaks: Bool {
        didSet { defaults.set(hotKeySpeaks, forKey: Key.hotKeySpeaks) }
    }
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var hotKeyConflict = false
    @Published private(set) var clipboardHotKeyConflict = false

    // MARK: Server data

    @Published private(set) var models: [OpenVoxItem] = []
    @Published private(set) var languages: [OpenVoxItem] = []
    @Published private(set) var voices: [OpenVoxItem] = []
    @Published private(set) var connection: ConnectionState = .unknown

    // MARK: Work state

    @Published var text = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var isStreamPlaying = false
    @Published private(set) var isPreloading = false
    @Published private(set) var statusText = "Not connected"
    @Published private(set) var statusIsError = false
    @Published private(set) var lastSavedFile: URL?
    @Published private(set) var lastClip: Data?

    let filePlayer = FilePlayer()
    private let streamPlayer = StreamingAudioPlayer()

    private var languagesTask: Task<Void, Never>?
    private var voicesTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?

    var isBusy: Bool { isGenerating || isStreamPlaying }

    init() {
        serverURL = defaults.string(forKey: Key.serverURL) ?? Self.defaultServerURL
        selectedModel = defaults.string(forKey: Key.model) ?? ""
        selectedLanguage = defaults.string(forKey: Key.language) ?? "en"
        selectedVoice = defaults.string(forKey: Key.voice) ?? ""
        streamAudio = defaults.object(forKey: Key.stream) as? Bool ?? true
        outputMode = OutputMode(rawValue: defaults.string(forKey: Key.outputMode) ?? "") ?? .play
        saveFolder = defaults.string(forKey: Key.saveFolder) ?? Self.defaultSaveFolder()
        volume = defaults.object(forKey: Key.volume) as? Double ?? 0.8
        filters = (defaults.data(forKey: Key.filters)).flatMap { try? JSONDecoder().decode([TextFilter].self, from: $0) } ?? []
        showFiltered = defaults.object(forKey: Key.showFiltered) as? Bool ?? false
        hotKeyEnabled = defaults.bool(forKey: Key.hotKeyEnabled)
        hotKeyCombo = (defaults.data(forKey: Key.hotKeyCombo)).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultCombo
        hotKeyMode = HotKeyMode(rawValue: defaults.string(forKey: Key.hotKeyMode) ?? "") ?? .replace
        hotKeySpeaks = defaults.bool(forKey: Key.hotKeySpeaks)
        clipboardHotKeyEnabled = defaults.bool(forKey: Key.clipboardHotKeyEnabled)
        clipboardHotKeyCombo = (defaults.data(forKey: Key.clipboardHotKeyCombo)).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultClipboardCombo
        filePlayer.volume = Float(volume)
        streamPlayer.volume = Float(volume)

        GlobalHotKey.shared.onPress = { [weak self] action in
            Task { @MainActor in await self?.handleHotKey(action) }
        }
        updateHotKeys(promptForAccess: false)
    }

    private static func defaultSaveFolder() -> String {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return music.appendingPathComponent("OpenVox TTS").path
    }

    private func makeClient() throws -> OpenVoxClient {
        guard let url = OpenVoxClient.normalizedBaseURL(serverURL) else {
            throw OpenVoxError.invalidURL(serverURL)
        }
        return OpenVoxClient(baseURL: url)
    }

    // MARK: Connecting and lists

    func connect() async {
        connection = .connecting
        setStatus("Connecting to \(serverURL)…")
        do {
            let client = try makeClient()
            let list = try await client.listModels()
            models = list
            connection = .connected
            setStatus("Connected. \(list.count) model\(list.count == 1 ? "" : "s") available.")
            if let first = list.first, !list.contains(where: { $0.id == selectedModel }) {
                selectedModel = first.id // didSet loads languages
            } else {
                reloadLanguages()
            }
        } catch {
            connection = .failed
            models = []
            setError("Couldn’t reach the server: \(error.localizedDescription)")
        }
    }

    private func reloadLanguages() {
        languagesTask?.cancel()
        let model = selectedModel
        guard !model.isEmpty else { return }
        languagesTask = Task {
            // Small debounce so typing a model name by hand doesn't fire a request per key.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let list = try await makeClient().languages(model: model)
                guard !Task.isCancelled else { return }
                languages = list
                if !list.isEmpty, !list.contains(where: { $0.id == selectedLanguage }) {
                    selectedLanguage = list.first(where: { $0.id.lowercased().hasPrefix("en") })?.id ?? list[0].id
                } else {
                    reloadVoices()
                }
            } catch {
                guard !Task.isCancelled else { return }
                languages = []
                reloadVoices()
            }
        }
    }

    private func reloadVoices() {
        voicesTask?.cancel()
        let model = selectedModel
        let language = selectedLanguage
        guard !model.isEmpty else { return }
        voicesTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let list = try await makeClient().voices(model: model, language: language)
                guard !Task.isCancelled else { return }
                voices = list
                if !list.isEmpty, !list.contains(where: { $0.id == selectedVoice }) {
                    selectedVoice = list[0].id
                }
            } catch {
                guard !Task.isCancelled else { return }
                voices = []
            }
        }
    }

    func preloadModel() async {
        guard !selectedModel.isEmpty else { return }
        isPreloading = true
        defer { isPreloading = false }
        setStatus("Loading \(selectedModel)…")
        do {
            try await makeClient().loadModel(selectedModel)
            setStatus("\(selectedModel) is loaded and ready.")
        } catch {
            setError("Preload failed: \(error.localizedDescription)")
        }
    }

    // MARK: Speaking

    func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            setText(string)
        }
    }

    /// Replaces the text, filtering it first when "Show filtered text" is on.
    func setText(_ newText: String) {
        if showFiltered {
            unfilteredText = newText
            let filtered = TextFilter.apply(filters, to: newText)
            lastFilteredText = filtered
            text = filtered
        } else {
            text = newText
        }
    }

    /// The text before filtering, as long as the filtered view hasn't been edited.
    private var sourceText: String {
        if showFiltered, text == lastFilteredText, let unfilteredText { return unfilteredText }
        return text
    }

    // MARK: Filtering

    func addFilter() -> TextFilter.ID {
        let filter = TextFilter(pattern: "")
        filters.append(filter)
        return filter.id
    }

    func removeFilters(_ ids: Set<TextFilter.ID>) {
        filters.removeAll { ids.contains($0.id) }
    }

    private func showFilteredText() {
        unfilteredText = text
        let filtered = TextFilter.apply(filters, to: text)
        lastFilteredText = filtered
        text = filtered
    }

    private func restoreUnfilteredText() {
        if let unfilteredText, text == lastFilteredText {
            text = unfilteredText
        }
        unfilteredText = nil
        lastFilteredText = nil
    }

    private func refilterIfShowing() {
        guard showFiltered else { return }
        setText(sourceText)
    }

    // MARK: Hot key

    func updateHotKeys(promptForAccess: Bool) {
        if hotKeyEnabled {
            hotKeyConflict = !GlobalHotKey.shared.register(hotKeyCombo, for: .pasteSelection)
            if promptForAccess && !SelectionGrabber.isTrusted {
                SelectionGrabber.requestAccess()
            }
        } else {
            GlobalHotKey.shared.unregister(.pasteSelection)
            hotKeyConflict = false
        }
        if clipboardHotKeyEnabled {
            clipboardHotKeyConflict = !GlobalHotKey.shared.register(clipboardHotKeyCombo, for: .pasteClipboard)
        } else {
            GlobalHotKey.shared.unregister(.pasteClipboard)
            clipboardHotKeyConflict = false
        }
        refreshAccessibilityStatus()
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = SelectionGrabber.isTrusted
    }

    func handleHotKey(_ action: HotKeyAction) async {
        switch action {
        case .pasteSelection: await pasteSelection()
        case .pasteClipboard: pasteClipboardFromHotKey()
        }
    }

    private func pasteClipboardFromHotKey() {
        guard let clip = NSPasteboard.general.string(forType: .string),
              !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            setError("The clipboard has no text.")
            return
        }
        insertFromHotKey(clip)
        setStatus("Pasted \(clip.count) characters from the clipboard.")
        if hotKeySpeaks { speak() }
    }

    /// Replaces or appends, per the hotkey mode.
    private func insertFromHotKey(_ newText: String) {
        switch hotKeyMode {
        case .replace:
            setText(newText)
        case .append:
            let current = sourceText
            let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n\n"
            setText(current + separator + newText)
        }
    }

    private func pasteSelection() async {
        refreshAccessibilityStatus()
        guard accessibilityTrusted else {
            SelectionGrabber.requestAccess()
            setError("TTS Buddy needs Accessibility access to read selected text. Turn it on in System Settings › Privacy & Security › Accessibility.")
            return
        }
        guard let selection = await SelectionGrabber.selectedText(),
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            setError("No selected text found in the front app.")
            return
        }
        insertFromHotKey(selection)
        setStatus("Grabbed \(selection.count) characters from the selection.")
        if hotKeySpeaks { speak() }
    }

    func speak() {
        let input = TextFilter.apply(filters, to: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            setError(text.isEmpty ? "Paste some text first." : "Nothing left to speak after filtering.")
            return
        }
        guard !selectedModel.isEmpty else {
            setError("Pick a model first (connect to the server to load the list).")
            return
        }
        stop()
        lastSavedFile = nil
        let model = selectedModel, language = selectedLanguage, voice = selectedVoice
        if streamAudio {
            speakTask = Task { await stream(input, model: model, language: language, voice: voice) }
        } else {
            let mode = outputMode
            speakTask = Task { await generate(input, model: model, language: language, voice: voice, mode: mode) }
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        streamPlayer.stop()
        filePlayer.stop()
        if isBusy { setStatus("Stopped.") }
        isGenerating = false
        isStreamPlaying = false
    }

    private func stream(_ input: String, model: String, language: String, voice: String) async {
        isGenerating = true
        isStreamPlaying = true
        setStatus("Streaming…")
        streamPlayer.begin { [weak self] in
            guard let self else { return }
            self.isStreamPlaying = false
            if let format = self.streamPlayer.receivedFormat, !self.streamPlayer.receivedPCM.isEmpty {
                self.lastClip = WAV.file(format: format, pcm: self.streamPlayer.receivedPCM)
            }
            if !self.statusIsError { self.setStatus("Done.") }
        }
        do {
            let client = try makeClient()
            var chunks = 0
            for try await chunk in client.streamSpeech(text: input, model: model, language: language, voice: voice) {
                try streamPlayer.enqueue(chunk)
                chunks += 1
            }
            isGenerating = false
            if chunks == 0 {
                streamPlayer.stop()
                isStreamPlaying = false
                setError("The server finished without sending any audio.")
            } else {
                setStatus("Playing…")
                streamPlayer.finishInput()
            }
        } catch is CancellationError {
            // stop() already reset state
        } catch {
            guard !Task.isCancelled else { return }
            isGenerating = false
            isStreamPlaying = false
            streamPlayer.stop()
            setError(error.localizedDescription)
        }
    }

    private func generate(_ input: String, model: String, language: String, voice: String, mode: OutputMode) async {
        isGenerating = true
        setStatus("Generating…")
        defer { isGenerating = false }
        do {
            let audio = try await makeClient().synthesize(text: input, model: model, language: language, voice: voice)
            guard !Task.isCancelled else { return }
            lastClip = audio
            switch mode {
            case .play:
                try filePlayer.load(audio)
                filePlayer.play()
                setStatus("Ready. \(Self.formatTime(filePlayer.duration)) clip.")
            case .save:
                let file = try save(audio, named: input)
                lastSavedFile = file
                setStatus("Saved \(file.lastPathComponent)")
            }
        } catch {
            guard !Task.isCancelled else { return }
            setError(error.localizedDescription)
        }
    }

    // MARK: Files

    private func save(_ audio: Data, named input: String) throws -> URL {
        let folder = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(Self.fileName(for: input))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(Self.fileName(for: input, suffix: " \(n)"))
            n += 1
        }
        try audio.write(to: url, options: .atomic)
        return url
    }

    private static func fileName(for input: String, suffix: String = "") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let words = input.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6).joined(separator: " ")
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let snippet = String(words.unicodeScalars.filter { !invalid.contains($0) }.prefix(40))
        let base = snippet.isEmpty ? formatter.string(from: Date()) : "\(formatter.string(from: Date())) - \(snippet)"
        return base + suffix + ".wav"
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            saveFolder = url.path
        }
    }

    func revealSaveFolder() {
        if let lastSavedFile {
            NSWorkspace.shared.activateFileViewerSelecting([lastSavedFile])
        } else {
            let folder = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// Saves the most recent clip (streamed or generated) wherever the user picks.
    func saveLastClipAs() {
        guard let lastClip else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = Self.fileName(for: text)
        panel.directoryURL = URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try lastClip.write(to: url, options: .atomic)
                lastSavedFile = url
                setStatus("Saved \(url.lastPathComponent)")
            } catch {
                setError("Couldn’t save: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Status

    private func setStatus(_ message: String) {
        statusText = message
        statusIsError = false
    }

    private func setError(_ message: String) {
        statusText = message
        statusIsError = true
    }

    static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
