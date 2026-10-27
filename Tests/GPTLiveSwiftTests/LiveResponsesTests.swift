import Foundation
import Testing
import AvatarBehavior
@testable import GPTLiveSwift

@MainActor
struct LiveResponsesTests {
    @Test func nativeLunaConfigurationIncludesSearchAndMemoryForBothPersonas() throws {
        for persona in AvatarPersona.allCases {
            var configuration = LiveConfiguration(instructions: persona.liveInstructions)
            var backend = AvatarDelegation.configuration(context: persona.identity)
            backend.tools = [AvatarDelegation.memoryTool, ["type": "web_search"]]
            configuration.responses = backend
            configuration.voice = persona.defaultVoice
            let request = configuration.request(offer: "test")
            let session = try #require(request["session"] as? [String: Any])
            #expect(session["model"] as? String == "gpt-live-1")
            let delegation = try #require(session["delegation"] as? [String: Any])
            #expect(delegation["type"] as? String == "responses")
            let responses = try #require(delegation["responses"] as? [String: Any])
            #expect(responses["model"] as? String == "gpt-6-luna")
            #expect(responses["parallel_tool_calls"] as? Bool == false)
            #expect(responses["tool_choice"] as? String == "auto")
            #expect((responses["instructions"] as? String)?.contains(persona.identity) == true)
            let tools = try #require(responses["tools"] as? [[String: Any]])
            #expect(tools.contains { $0["type"] as? String == "web_search" })
            #expect(tools.contains { $0["name"] as? String == "memory_control" })
        }
    }

    @Test func collectsDoneItemsAndReturnsEveryResultBeforeContinuing() async throws {
        var sent: [[String: Any]] = []
        var executed: [String] = []
        let responses = LiveResponses { sent.append($0) }
        responses.execute = { call in executed.append(call.id); return "Success \(call.id)" }
        try begin(responses)
        try call(responses, id: "first")
        try call(responses, id: "first")
        try call(responses, id: "second")
        #expect(executed.isEmpty)
        try complete(responses)
        await settle()
        #expect(executed == ["first", "second"])
        #expect(sent.compactMap { $0["type"] as? String } == ["response.item.create", "response.item.create", "response.create"])
        let items = sent.compactMap { $0["item"] as? [String: Any] }
        #expect(items.compactMap { $0["call_id"] as? String } == ["first", "second"])
        #expect(items.allSatisfy { $0["type"] as? String == "function_call_output" })
        try begin(responses)
        try call(responses, id: "first")
        try complete(responses)
        await settle()
        #expect(executed.count == 2)
    }

    @Test func failedAndStaleResponsesCannotMutateMemory() async throws {
        var sent: [[String: Any]] = []
        var executed = false
        var errors: [String] = []
        let responses = LiveResponses { sent.append($0) }
        responses.execute = { _ in executed = true; return "Should not run" }
        responses.onError = { errors.append($0) }
        try begin(responses)
        try call(responses, id: "save")
        responses.invalidate()
        try complete(responses)
        await settle()
        #expect(!executed)
        #expect(((sent.first?["item"] as? [String: Any])?["output"] as? String)?.contains("cancelled") == true)
        sent.removeAll()
        try begin(responses, id: "failed")
        try call(responses, id: "save")
        try responses.receive(delegationID: "delegation", event: ["type": "response.incomplete", "response": ["id": "failed"]])
        await settle()
        #expect(!executed)
        #expect(sent.isEmpty)
        #expect(errors.count == 1)
    }

    @Test func closingWhileAwaitingConfirmationDiscardsLateResults() async throws {
        var sent: [[String: Any]] = []
        var permission: CheckedContinuation<Void, Never>?
        let responses = LiveResponses { sent.append($0) }
        responses.execute = { _ in
            await withCheckedContinuation { permission = $0 }
            try Task.checkCancellation()
            return "Saved"
        }
        try begin(responses)
        try call(responses, id: "save")
        try complete(responses)
        await settle()
        let continuation = try #require(permission)
        responses.close()
        continuation.resume()
        await settle()
        #expect(sent.isEmpty)
    }

    @Test func lateSupersededDelegationsCannotBecomeActiveAgain() async throws {
        var sent: [[String: Any]] = []
        var executed = false
        let responses = LiveResponses { sent.append($0) }
        responses.execute = { _ in executed = true; return "Must not run" }
        try begin(responses)
        try call(responses, id: "old-save")
        responses.activate(delegationID: "new-delegation")
        try complete(responses)
        try begin(responses, id: "late-old-response")
        try call(responses, id: "late-save")
        try complete(responses, id: "late-old-response")
        await settle()
        #expect(!executed)
        #expect(sent.isEmpty)
    }

    @Test func argumentsDoneIsNotACompleteCallAndFailuresAreReturned() async throws {
        var sent: [[String: Any]] = []
        let responses = LiveResponses { sent.append($0) }
        responses.execute = { _ in throw LiveError.message("User declined") }
        try begin(responses)
        try responses.receive(delegationID: "delegation", event: ["type": "response.function_call_arguments.done", "arguments": "{}"])
        try complete(responses)
        await settle()
        #expect(sent.isEmpty)
        try begin(responses, id: "next")
        try call(responses, id: "failure")
        try complete(responses, id: "next")
        await settle()
        #expect(((sent.first?["item"] as? [String: Any])?["output"] as? String) == "Action failed: User declined")
        #expect(sent.last?["type"] as? String == "response.create")
    }

    @Test func citationsPreserveUnicodeAndRejectUnsafeLinks() throws {
        let message = try #require(LiveBackendMessage(item: Self.citedItem))
        #expect(message.text == "🐼 Swift [1]")
        #expect(message.citations.count == 1)
        #expect(message.citations[0].url.absoluteString == "https://www.swift.org/")
        #expect(message.citations[0].start == 8)
        var transcript = ConversationTranscript(maximumEntries: 2, maximumCharacters: 50)
        transcript.appendBackend(message, characterName: "Rei", milliseconds: 100)
        #expect(transcript.entries[0].name == "Rei · Web sources")
        #expect(transcript.entries[0].citations.count == 1)
        transcript.append(LiveTranscript(speaker: .user, delta: String(repeating: "a", count: 45),
            startMilliseconds: 200, endMilliseconds: 300), characterName: "Poldo")
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].citations.isEmpty)
        #expect(transcript.wasTrimmed)
    }

    @Test func explicitMarkdownSourcesAreClickableWithoutAnnotations() throws {
        let message = try #require(LiveBackendMessage(item: ["type": "message", "id": "markdown", "content": [
            ["type": "output_text", "text": "🐼 See [Swift](https://www.swift.org/).", "annotations": []]
        ]]))
        #expect(message.citations.count == 1)
        #expect(message.citations[0].title == "Swift")
        #expect(message.citations[0].start == 6)
        #expect(message.citations[0].url.absoluteString == "https://www.swift.org/")
    }

    @Test func citedMessagesArriveOnceAndOnlyOnSuccessfulCompletion() throws {
        var messages: [LiveBackendMessage] = []
        let responses = LiveResponses { _ in }
        responses.onMessage = { messages.append($0) }
        try begin(responses)
        responses.activate(delegationID: "delegation")
        for _ in 0..<2 {
            try responses.receive(delegationID: "delegation", event: ["type": "response.output_item.done", "item": Self.citedItem])
        }
        #expect(messages.isEmpty)
        try complete(responses)
        #expect(messages.count == 1)
        try complete(responses)
        #expect(messages.count == 1)
    }

    static var citedItem: [String: Any] {
        ["id": "message", "type": "message", "content": [["type": "output_text", "text": "🐼 Swift [1]", "annotations": [
            ["type": "url_citation", "start_index": 8, "end_index": 11, "title": "Swift", "url": "https://www.swift.org/"],
            ["type": "url_citation", "start_index": 0, "end_index": 1, "title": "Unsafe", "url": "file:///etc/passwd"],
            ["type": "url_citation", "start_index": 0, "end_index": 99, "title": "Invalid", "url": "https://example.com"]
        ]]]]
    }

    private func begin(_ responses: LiveResponses, id: String = "response") throws {
        try responses.receive(delegationID: "delegation", event: ["type": "response.created", "response": ["id": id]])
    }

    private func call(_ responses: LiveResponses, id: String) throws {
        try responses.receive(delegationID: "delegation", event: ["type": "response.output_item.done",
            "item": ["type": "function_call", "call_id": id, "name": "memory_control", "arguments": "{}"]])
    }

    private func complete(_ responses: LiveResponses, id: String = "response") throws {
        try responses.receive(delegationID: "delegation", event: ["type": "response.completed",
            "response": ["id": id, "status": "completed", "output": []]])
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}
