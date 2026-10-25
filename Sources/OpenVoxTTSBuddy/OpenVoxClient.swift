import Foundation

/// A model, language or voice returned by the server.
struct OpenVoxItem: Identifiable, Hashable {
    let id: String
    let label: String
}

enum OpenVoxError: LocalizedError {
    case invalidURL(String)
    case busy
    case http(Int, String)
    case server(String)
    case notAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "“\(raw)” isn’t a valid server URL."
        case .busy:
            return "The server is busy with another generation or preload. Wait a moment and try again."
        case .http(let code, let body):
            let detail = body.isEmpty ? "" : ": \(body)"
            return "Server returned HTTP \(code)\(detail)"
        case .server(let message):
            return "Server error: \(message)"
        case .notAudio(let body):
            return "Server didn’t return audio: \(body)"
        }
    }
}

/// Talks to the OpenVox local API (https://openvoxai.com/support#local-api).
///
/// The docs only show example requests, not response schemas, so list
/// responses are parsed leniently: plain string arrays, `{data: [...]}`,
/// `{voices: [...]}`, objects with `id`/`name`, and so on.
struct OpenVoxClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        // Model loads and long generations can take a while on the server.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Accepts `192.168.1.3:18778`, `http://host:port`, or `http://host:port/v1`
    /// and returns a base URL that always ends in `/v1`.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasSuffix("/v1") { s += "/v1" }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: - Endpoints

    func listModels() async throws -> [OpenVoxItem] {
        let data = try await get(path: "models")
        return Self.items(fromJSON: data)
    }

    func loadModel(_ model: String) async throws {
        var request = URLRequest(url: url(path: "models/\(escape(model))/load"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
    }

    func languages(model: String) async throws -> [OpenVoxItem] {
        let data = try await get(path: "models/\(escape(model))/languages")
        return Self.items(fromJSON: data)
    }

    func voices(model: String, language: String) async throws -> [OpenVoxItem] {
        var query: [URLQueryItem] = []
        if !language.isEmpty { query.append(URLQueryItem(name: "language", value: language)) }
        let data = try await get(path: "models/\(escape(model))/voices", query: query)
        return Self.items(fromJSON: data)
    }

    /// Generates the whole clip and returns it as WAV data.
    func synthesize(text: String, model: String, language: String, voice: String) async throws -> Data {
        let request = speechRequest(text: text, model: model, language: language, voice: voice, stream: false)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        if let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           type.contains("json") || type.contains("text/") {
            throw OpenVoxError.notAudio(Self.snippet(data))
        }
        return data
    }

    /// Streams speech. Each element is a decoded audio chunk: the first one is
    /// normally a WAV file (header + PCM), later ones may be WAV or raw PCM.
    func streamSpeech(text: String, model: String, language: String, voice: String) -> AsyncThrowingStream<Data, Error> {
        let request = speechRequest(text: text, model: model, language: language, voice: voice, stream: true)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    if let http, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 4096 { break }
                        }
                        try Self.check(response, body: body)
                    }
                    let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    if contentType.hasPrefix("audio/") || contentType.contains("octet-stream") {
                        // Server streamed raw audio instead of SSE.
                        var buffer = Data()
                        buffer.reserveCapacity(32 * 1024)
                        for try await byte in bytes {
                            buffer.append(byte)
                            if buffer.count >= 32 * 1024 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                        if !buffer.isEmpty { continuation.yield(buffer) }
                    } else {
                        try await Self.parseServerSentEvents(bytes.lines, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - SSE

    /// Handles `response.created`, `audio.chunk` and `response.completed` events.
    /// `AsyncLineSequence` drops blank lines, so each `data:` line is handled as
    /// soon as it forms complete JSON instead of waiting for the blank separator.
    private static func parseServerSentEvents<S: AsyncSequence>(
        _ lines: S,
        into continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws where S.Element == String {
        var eventName = ""
        var pendingData = ""
        for try await rawLine in lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty || line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                pendingData = ""
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            pendingData += payload
            guard let json = try? JSONSerialization.jsonObject(with: Data(pendingData.utf8)),
                  let object = json as? [String: Any] else {
                continue // wait for more data lines
            }
            pendingData = ""
            let type = (object["type"] as? String) ?? (object["event"] as? String) ?? eventName
            eventName = ""

            if type.lowercased().contains("error") || object["error"] != nil {
                throw OpenVoxError.server(errorMessage(in: object) ?? "unknown error")
            }
            if let base64 = audioBase64(in: object), let audio = decodeBase64(base64), !audio.isEmpty {
                continuation.yield(audio)
            }
            if type == "response.completed" || type == "done" { return }
        }
    }

    private static func audioBase64(in object: [String: Any]) -> String? {
        if let s = object["audio"] as? String { return s }
        if let nested = object["audio"] as? [String: Any], let s = nested["data"] as? String { return s }
        if let nested = object["data"] as? [String: Any] { return audioBase64(in: nested) }
        if let nested = object["chunk"] as? [String: Any] { return audioBase64(in: nested) }
        if let s = object["delta"] as? String { return s }
        return nil
    }

    private static func decodeBase64(_ string: String) -> Data? {
        var s = string
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            s = String(s[s.index(after: comma)...])
        }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    private static func errorMessage(in object: [String: Any]) -> String? {
        if let s = object["error"] as? String { return s }
        if let e = object["error"] as? [String: Any] { return (e["message"] as? String) ?? (e["detail"] as? String) }
        if let d = object["data"] as? [String: Any] { return errorMessage(in: d) ?? (d["message"] as? String) }
        return (object["message"] as? String) ?? (object["detail"] as? String)
    }

    // MARK: - Helpers

    private func url(path: String, query: [URLQueryItem] = []) -> URL {
        var string = baseURL.absoluteString
        if !string.hasSuffix("/") { string += "/" }
        string += path
        var components = URLComponents(string: string)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func escape(_ component: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    private func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        var request = URLRequest(url: url(path: path, query: query))
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, body: data)
        return data
    }

    private func speechRequest(text: String, model: String, language: String, voice: String, stream: Bool) -> URLRequest {
        var request = URLRequest(url: url(path: "audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "audio/wav", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model,
            "input": text,
            "response_format": "wav",
            "stream": stream,
        ]
        if !language.isEmpty { body["language"] = language }
        if !voice.isEmpty { body["voice"] = voice }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 429 { throw OpenVoxError.busy }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenVoxError.http(http.statusCode, snippet(body))
        }
    }

    private static func snippet(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = errorMessage(in: json) {
            return message
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lenient list parsing

    static func items(fromJSON data: Data) -> [OpenVoxItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var seen = Set<String>()
        return items(from: json).filter { seen.insert($0.id).inserted }
    }

    private static let listKeys = ["data", "models", "voices", "languages", "items", "results"]

    private static func items(from json: Any) -> [OpenVoxItem] {
        if let array = json as? [Any] {
            return array.compactMap(item(from:))
        }
        if let dict = json as? [String: Any] {
            for key in listKeys where dict[key] != nil {
                return items(from: dict[key]!)
            }
            // A map like {"en": "English"} or {"af_bella": {...}}.
            return dict.keys.sorted().map { key in
                if let name = dict[key] as? String, name != key {
                    return OpenVoxItem(id: key, label: "\(name) (\(key))")
                }
                if let object = dict[key] as? [String: Any], let name = displayName(in: object), name != key {
                    return OpenVoxItem(id: key, label: "\(name) (\(key))")
                }
                return OpenVoxItem(id: key, label: key)
            }
        }
        return []
    }

    private static func item(from value: Any) -> OpenVoxItem? {
        if let s = value as? String { return OpenVoxItem(id: s, label: s) }
        guard let object = value as? [String: Any] else { return nil }
        let idKeys = ["id", "code", "voice_id", "voice", "model", "language", "lang", "name"]
        guard let id = idKeys.lazy.compactMap({ object[$0] as? String }).first else { return nil }
        if let name = displayName(in: object), name != id {
            return OpenVoxItem(id: id, label: "\(name) (\(id))")
        }
        return OpenVoxItem(id: id, label: id)
    }

    private static func displayName(in object: [String: Any]) -> String? {
        ["display_name", "displayName", "label", "title", "name"].lazy.compactMap { object[$0] as? String }.first
    }
}
