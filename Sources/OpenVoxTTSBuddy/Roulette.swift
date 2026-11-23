import Foundation

/// One model + language + voice combination in the roulette pool.
struct RouletteEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var model: String
    var language: String
    var voice: String
    /// Display names captured when the entry was added.
    var modelLabel: String
    var voiceLabel: String

    var title: String {
        let voicePart = voice.isEmpty ? "default voice" : voiceLabel
        return language.isEmpty ? "\(modelLabel) · \(voicePart)" : "\(modelLabel) · \(voicePart) · \(language)"
    }

    func matches(model: String, language: String, voice: String) -> Bool {
        self.model == model && self.language == language && self.voice == voice
    }

    /// A random entry, avoiding `previous` when there's anything else to pick.
    static func pick(from entries: [RouletteEntry], avoiding previous: RouletteEntry.ID?) -> RouletteEntry? {
        let others = entries.filter { $0.id != previous }
        return (others.isEmpty ? entries : others).randomElement()
    }
}

enum UpNextState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}
