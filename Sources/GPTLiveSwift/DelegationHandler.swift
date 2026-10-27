import Foundation

/// A small client-delegation backend. App-owned tools run on the main actor.
@MainActor
public final class ResponsesDelegationHandler {
    private let http: OpenAIHTTP
    private let model: String
    private var completedActions: [String] = []

    public init(http: OpenAIHTTP, model: String = "gpt-6-luna") {
        self.http = http
        self.model = model
    }

    public func handle(_ request: LiveDelegation, context: String, tools: [[String: Any]],
                       execute: (String, String) throws -> String) async throws -> String {
        let fragments = request.transcript.sorted { $0.startMilliseconds < $1.startMilliseconds }
        var turns: [(speaker: LiveTranscript.Speaker, text: String)] = []
        for fragment in fragments {
            if turns.last?.speaker == fragment.speaker {
                turns[turns.count - 1].text += fragment.delta
            } else { turns.append((fragment.speaker, fragment.delta)) }
        }
        let history = turns.suffix(40).map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        var input: [[String: Any]] = [["role": "user", "content": """
        Current avatar state: \(context)
        Already completed app actions (do not repeat): \(completedActions.joined(separator: "; "))
        Voice transcript through delegation at \(request.offsetMilliseconds) ms:
        \(history)
        Handle the latest outstanding user request or the avatar's latest stated expression choice.
        Older transcript is context only.
        """
        ]]
        for _ in 0..<4 {
            try Task.checkCancellation()
            let data = try await http.post(path: "responses", body: [
                "model": model, "store": false, "max_output_tokens": 1200,
                "instructions": """
                You are the backend for a talking Live2D avatar. Interpret the latest voice request using the
                transcript and current app state. Use only the provided tools for avatar changes.
                The current app identity is authoritative: know the character's name and appearance.
                After an avatar switch, use the new identity from the tool result. Ordinary conversation is
                happy, excited and bubbly, but sad news deserves tenderness, criticism may feel briefly hurt,
                and mistakes deserve sincere accountability. Never guilt-trip or demand reassurance.
                You may choose an emotion or a named expression spontaneously when automatic emotions are
                enabled, including a choice voiced by the avatar; other UI changes require a user request.
                Use the current expression catalog's names and visual descriptions. Expressions replace the
                previous preset. Neutral restores the default look. Prefer emotions for ordinary feelings;
                do not choose an expression with no visible effect as a reaction. Respect a user-requested
                held look and manual emotions when automatic emotions are disabled.
                Transcript fragments may be incomplete or mistaken; ask a brief clarification when ambiguous.
                Never claim an action succeeded until its tool returns success. Do not replay completed requests.
                Answer general reasoning questions concisely; you have no web, shell, file, or messaging tools.
                Return a short plain-text result for the voice model, ideally under 60 words.
                """,
                "input": input, "tools": tools, "parallel_tool_calls": false
            ])
            try Task.checkCancellation()
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["status"] as? String == "completed", let output = response["output"] as? [[String: Any]] else {
                throw LiveError.message("The voice command backend did not complete its response.")
            }
            input.append(contentsOf: output)
            let calls = output.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty {
                let text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
                    .joined(separator: " ")
                return Self.brief(text.isEmpty ? "No action was taken. Please repeat the request." : text)
            }
            for call in calls {
                try Task.checkCancellation()
                guard let name = call["name"] as? String, let arguments = call["arguments"] as? String,
                      let id = call["call_id"] as? String else { throw LiveError.message("Invalid voice command from the backend.") }
                let result: String
                do {
                    result = try execute(name, arguments)
                    completedActions.append("At \(request.offsetMilliseconds) ms: \(result)")
                    completedActions = Array(completedActions.suffix(30))
                } catch { result = "Action failed: \(error.localizedDescription)" }
                input.append(["type": "function_call_output", "call_id": id, "output": result])
            }
        }
        return "The command sequence reached its limit. Some actions may have completed; ask about the current avatar state."
    }

    public static func brief(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= 470 else { break }
            result.append(character)
        }
        return result
    }
}
