import Foundation

public enum LiveError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public struct LiveTranscript: Equatable {
    public enum Speaker: String { case user, assistant }
    public let speaker: Speaker
    public let delta: String
    public let startMilliseconds: Int
    public let endMilliseconds: Int

    public init(speaker: Speaker, delta: String, startMilliseconds: Int, endMilliseconds: Int) {
        self.speaker = speaker
        self.delta = delta
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}

public struct LiveDelegation {
    public let id: String
    public let offsetMilliseconds: Int
    public let transcript: [LiveTranscript]
}

/// Live events deliberately differ from the older Realtime API event schema.
enum LiveEvent {
    case started(String)
    case transcript(LiveTranscript)
    case delegation(id: String, offset: Int)
    case responsesDelegation(String)
    case responseEvent(delegationID: String, event: [String: Any])
    case usage(Double)
    case closed(seconds: Double?, reason: String)
    case error(String)
    case other

    static func decode(_ data: Data) throws -> LiveEvent {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let type = object["type"] as? String ?? ""
        switch type {
        case "session.started":
            guard let session = object["session"] as? [String: Any], let id = session["id"] as? String else {
                throw LiveError.message("Live returned a session without an ID.")
            }
            return .started(id)
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let delta = object["delta"] as? String,
                  let start = object["start_ms"] as? Int, let end = object["end_ms"] as? Int else {
                throw LiveError.message("Live returned an invalid transcript event.")
            }
            return .transcript(LiveTranscript(speaker: type == "session.input_transcript.delta" ? .user : .assistant,
                delta: delta, startMilliseconds: start, endMilliseconds: end))
        case "session.delegation.created":
            if let delegation = object["delegation"] as? [String: Any],
               delegation["target"] as? String == "responses", let id = delegation["id"] as? String {
                return .responsesDelegation(id)
            }
            guard let delegation = object["delegation"] as? [String: Any],
                  delegation["target"] as? String == "client", let id = delegation["id"] as? String,
                  let offset = object["offset_ms"] as? Int else { return .other }
            return .delegation(id: id, offset: offset)
        case "response.event":
            guard let id = object["delegation_id"] as? String, let event = object["event"] as? [String: Any] else {
                throw LiveError.message("Malformed Responses event envelope.")
            }
            return .responseEvent(delegationID: id, event: event)
        case "session.usage.updated":
            let usage = object["usage"] as? [String: Any]
            return .usage(usage?["seconds"] as? Double ?? 0)
        case "session.closed":
            let usage = object["usage"] as? [String: Any]
            return .closed(seconds: usage?["seconds"] as? Double, reason: object["reason"] as? String ?? "closed")
        case "error":
            // Do not surface arbitrary server payloads: they may echo credentials or SDP.
            let error = object["error"] as? [String: Any]
            let code = (error?["code"] as? String ?? "unknown").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            return .error("The Live service rejected a session command (\(code.prefix(80))).")
        default: return .other
        }
    }
}
