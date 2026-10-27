import Foundation

public struct LiveConfiguration {
    public var model = "gpt-live-1"
    public var voice = "marin"
    public var instructions: String
    public var responses: LiveResponsesConfiguration?

    public init(instructions: String) { self.instructions = instructions }

    func request(offer: String) -> [String: Any] {
        ["session": ["model": model, "instructions": instructions,
                     "audio": ["output": ["voice": voice]],
                     "delegation": responses.map { ["type": "responses", "responses": $0.request] } ?? ["type": "client"], "store": false],
         "transport": ["type": "webrtc", "sdp": offer]]
    }
}

public struct LiveSession: Decodable {
    public struct Identity: Decodable { public let id: String }
    public struct Transport: Decodable { public let type: String; public let sdp: String }
    public let session: Identity
    public let transport: Transport
}

public protocol LiveSessionService {
    func create(offer: String, configuration: LiveConfiguration) async throws -> LiveSession
    func hangup(id: String) async
}

public enum LocalOpenAIKey {
    /// Read only at the user's Start action. Never bundle or print credentials.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let value: String
        if let key = environment["OPENAI_API_KEY"], !key.isEmpty {
            value = key
        } else {
            guard let key = try? String(contentsOf: home.appendingPathComponent(".openai_api_key"), encoding: .utf8) else {
                throw LiveError.message("Set OPENAI_API_KEY or put your API key in ~/.openai_api_key, then start voice again.")
            }
            value = key
        }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 12, !key.contains(where: { $0.isWhitespace }) else {
            throw LiveError.message("The OpenAI key must be a single API key, not a URL or shell command. Check OPENAI_API_KEY and ~/.openai_api_key.")
        }
        return key
    }
}

/// Prevent authentication headers and SDP from following server redirects.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class OpenAIHTTP {
    private let key: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession? = nil) {
        key = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func post(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return data
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw LiveError.message("Invalid voice service response.") }
        guard (200..<300).contains(http.statusCode) else {
            let guidance: String
            switch http.statusCode {
            case 401: guidance = "Check your API key."
            case 403, 404: guidance = "Check that your OpenAI project has access to the requested model and Live API."
            case 429: guidance = "Check your project quota or try again later."
            default: guidance = "Try again later; verify the session configuration if this continues."
            }
            throw LiveError.message("Voice service HTTP \(http.statusCode). \(guidance)")
        }
    }
}

/// Intended for this single-user desktop app. Distributed apps should use a trusted backend.
public struct DirectLiveSessionService: LiveSessionService {
    private let http: OpenAIHTTP
    public init(http: OpenAIHTTP) { self.http = http }

    public func create(offer: String, configuration: LiveConfiguration) async throws -> LiveSession {
        let data = try await http.post(path: "live/sessions", body: configuration.request(offer: offer))
        return try JSONDecoder().decode(LiveSession.self, from: data)
    }

    public func hangup(id: String) async {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        _ = try? await http.post(path: "live/sessions/\(escaped)/hangup", body: [:])
    }
}

/// The backend accepts {sdp}, owns configuration/authentication, and returns the Live create response.
public struct BackendLiveSessionService: LiveSessionService {
    private let url: URL
    private let session: URLSession
    private let hangupSession: (String) async -> Void

    public init(sessionURL: URL, hangup: @escaping (String) async -> Void) throws {
        guard sessionURL.scheme == "https" || (sessionURL.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(sessionURL.host ?? "")) else {
            throw LiveError.message("Use HTTPS for the voice backend, or HTTP on localhost during development.")
        }
        url = sessionURL
        hangupSession = hangup
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func create(offer: String, configuration: LiveConfiguration) async throws -> LiveSession {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sdp": offer])
        let (data, response) = try await session.data(for: request)
        try OpenAIHTTP.check(response)
        return try JSONDecoder().decode(LiveSession.self, from: data)
    }

    public func hangup(id: String) async { await hangupSession(id) }
}
