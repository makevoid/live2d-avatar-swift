import Foundation

public struct LiveResponsesConfiguration {
    public var model: String
    public var instructions: String
    public var tools: [[String: Any]]

    public init(model: String = "gpt-6-luna", instructions: String, tools: [[String: Any]]) {
        self.model = model
        self.instructions = instructions
        self.tools = tools
    }

    var request: [String: Any] {
        ["model": model, "instructions": instructions, "tools": tools,
         "tool_choice": "auto", "parallel_tool_calls": false, "max_output_tokens": 1200]
    }
}

public struct LiveToolCall: Equatable {
    public let id: String
    public let name: String
    public let arguments: String
}

public struct LiveCitation: Equatable {
    public let title: String
    public let url: URL
    public let start: Int
    public let end: Int
}

public struct LiveBackendMessage: Equatable {
    public let id: String
    public let text: String
    public let citations: [LiveCitation]

    public init?(item: [String: Any]) {
        guard item["type"] as? String == "message", let id = item["id"] as? String,
              let content = item["content"] as? [[String: Any]] else { return nil }
        var text = ""
        var citations: [LiveCitation] = []
        for part in content where part["type"] as? String == "output_text" {
            guard let body = part["text"] as? String else { continue }
            if !text.isEmpty { text += "\n" }
            let offset = text.unicodeScalars.count
            for annotation in part["annotations"] as? [[String: Any]] ?? [] {
                guard annotation["type"] as? String == "url_citation",
                      let rawURL = annotation["url"] as? String, let url = URL(string: rawURL),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                      let start = annotation["start_index"] as? Int, let end = annotation["end_index"] as? Int,
                      start >= 0, end > start, end <= body.unicodeScalars.count else { continue }
                citations.append(LiveCitation(title: annotation["title"] as? String ?? host,
                    url: url, start: offset + start, end: offset + end))
            }
            text += body
        }
        guard !text.isEmpty else { return nil }
        if let pattern = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#) {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let titleRange = Range(match.range(at: 1), in: text),
                      let urlRange = Range(match.range(at: 2), in: text), let url = URL(string: String(text[urlRange])),
                      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { continue }
                let start = text.unicodeScalars.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.unicodeScalars.distance(from: text.startIndex, to: range.upperBound)
                guard !citations.contains(where: { $0.start < end && $0.end > start }) else { continue }
                citations.append(LiveCitation(title: String(text[titleRange]), url: url, start: start, end: end))
            }
        }
        self.id = id
        self.text = text
        self.citations = citations
    }
}

@MainActor
final class LiveResponses {
    private struct Pending {
        let id: String
        let revision: Int
        var calls: [LiveToolCall] = []
        var messages: [LiveBackendMessage] = []
    }

    var execute: ((LiveToolCall) async throws -> String)?
    var onMessage: ((LiveBackendMessage) -> Void)?
    var onError: ((String) -> Void)?
    private let send: ([String: Any]) throws -> Void
    private var pending: [String: Pending] = [:]
    private var finished: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var revision = 0
    private var activeDelegationID: String?
    private var retiredDelegations: [String] = []

    init(send: @escaping ([String: Any]) throws -> Void) { self.send = send }

    @discardableResult
    func activate(delegationID: String) -> Bool {
        guard !retiredDelegations.contains(delegationID) else { return false }
        guard delegationID != activeDelegationID else { return true }
        if let activeDelegationID {
            retiredDelegations.append(activeDelegationID)
            retiredDelegations = Array(retiredDelegations.suffix(256))
        }
        invalidate()
        activeDelegationID = delegationID
        pending = pending.filter { $0.key == delegationID }
        return true
    }

    func invalidate() {
        revision += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func close() {
        invalidate()
        pending.removeAll()
    }

    func receive(delegationID: String, event: [String: Any]) throws {
        switch event["type"] as? String {
        case "response.created":
            guard let response = event["response"] as? [String: Any], let id = response["id"] as? String,
                  !finished.contains(id), pending[delegationID]?.id != id else { return }
            guard activate(delegationID: delegationID) else { return }
            guard pending.count < 32 else { throw LiveError.message("Too many pending delegated responses.") }
            pending[delegationID] = Pending(id: id, revision: revision)
        case "response.output_item.done":
            guard var response = pending[delegationID], let item = event["item"] as? [String: Any],
                  event["response_id"] == nil || event["response_id"] as? String == response.id else { return }
            if item["type"] as? String == "function_call" {
                guard let id = item["call_id"] as? String, let name = item["name"] as? String,
                      let arguments = item["arguments"] as? String, arguments.utf8.count <= 8192 else {
                    throw LiveError.message("Malformed delegated tool call.")
                }
                if !response.calls.contains(where: { $0.id == id }) {
                    guard response.calls.count < 16 else { throw LiveError.message("Too many delegated tool calls.") }
                    response.calls.append(LiveToolCall(id: id, name: name, arguments: arguments))
                }
            } else if let message = LiveBackendMessage(item: item), !response.messages.contains(where: { $0.id == message.id }) {
                response.messages.append(message)
            }
            pending[delegationID] = response
        case "response.completed", "response.failed", "response.incomplete", "response.cancelled":
            guard let object = event["response"] as? [String: Any], let id = object["id"] as? String,
                  let response = pending[delegationID], response.id == id else { return }
            pending.removeValue(forKey: delegationID)
            finished.append(id)
            finished = Array(finished.suffix(256))
            guard event["type"] as? String == "response.completed" else {
                onError?("Luna could not complete the delegated request. Please try again.")
                return
            }
            if response.revision == revision {
                for message in response.messages { onMessage?(message) }
            }
            guard !response.calls.isEmpty else { return }
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                defer { self.tasks.removeValue(forKey: id) }
                do {
                    for call in response.calls {
                        try Task.checkCancellation()
                        let result: String
                        do {
                            guard response.revision == self.revision else { throw CancellationError() }
                            guard let execute = self.execute else { throw LiveError.message("This tool is not available.") }
                            result = try await execute(call)
                        } catch is CancellationError {
                            result = "Action cancelled because the session or app context changed. Ask again if still needed."
                        } catch { result = "Action failed: \(error.localizedDescription)" }
                        try Task.checkCancellation()
                        try self.send(["type": "response.item.create", "event_id": UUID().uuidString,
                                       "item": ["type": "function_call_output", "call_id": call.id, "output": result]])
                    }
                    try self.send(["type": "response.create", "event_id": UUID().uuidString])
                } catch is CancellationError { }
                catch { self.onError?("Could not return a delegated tool result. Stop and restart voice before retrying.") }
            }
        default: break
        }
    }
}
