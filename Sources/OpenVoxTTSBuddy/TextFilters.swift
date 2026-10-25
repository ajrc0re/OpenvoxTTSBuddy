import Foundation

/// A regular expression whose matches are removed from the text before speaking.
struct TextFilter: Identifiable, Codable, Hashable {
    var id = UUID()
    var pattern: String
    var isEnabled = true

    /// nil when the pattern is empty or invalid.
    var regex: NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    var errorMessage: String? {
        guard !pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            return nil
        } catch {
            return "Invalid pattern: \((error as NSError).localizedDescription)"
        }
    }

    static func apply(_ filters: [TextFilter], to text: String) -> String {
        filters.reduce(text) { result, filter in
            guard filter.isEnabled, let regex = filter.regex else { return result }
            let range = NSRange(result.startIndex..., in: result)
            return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
    }
}
