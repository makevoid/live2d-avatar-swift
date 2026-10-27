import Foundation
import Testing
import AvatarBehavior
@testable import GPTLiveSwift

@MainActor
private final class FakeTransport: LiveTransport {
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    var microphoneEnabled = false
    var closed = false
    var startedAutomatically = true
    var sent: [[String: Any]] = []
    func offer() async throws -> String { "test-offer" }
    func accept(answer: String) async throws {
        #expect(answer == "test-answer")
        if startedAutomatically { emit(["type": "session.started", "session": ["id": "live_test"]]) }
    }
    func send(_ data: Data) throws { sent.append(try JSONSerialization.jsonObject(with: data) as! [String: Any]) }
    func setMicrophone(enabled: Bool) { microphoneEnabled = enabled }
    func close() { closed = true; microphoneEnabled = false; onAudioLevel?(0) }
    func emit(_ object: [String: Any]) { onMessage?(try! JSONSerialization.data(withJSONObject: object)) }
}

private actor FakeService: LiveSessionService {
    var hangups: [String] = []
    var createDelay: UInt64 = 0
    var created = false
    func delay(_ nanos: UInt64) { createDelay = nanos }
    func create(offer: String, configuration: LiveConfiguration) async throws -> LiveSession {
        #expect(offer == "test-offer")
        created = true
        // Deliberately finish even if canceled to reproduce a late HTTP success.
        if createDelay > 0 { try? await Task.sleep(nanoseconds: createDelay) }
        return try JSONDecoder().decode(LiveSession.self,
            from: Data(#"{"session":{"id":"live_test"},"transport":{"type":"webrtc","sdp":"test-answer"}}"#.utf8))
    }
    func hangup(id: String) async { hangups.append(id) }
}

@Suite(.serialized)
@MainActor
struct LiveTests {
    @Test func liveRequestUsesDocumentedSchema() throws {
        let request = LiveConfiguration(instructions: "Test").request(offer: "offer")
        let session = try #require(request["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-live-1")
        #expect(session["store"] as? Bool == false)
        #expect((session["delegation"] as? [String: String])?["type"] == "client")
        let audio = try #require(session["audio"] as? [String: Any])
        #expect(audio["format"] == nil)
        #expect((audio["output"] as? [String: String])?["voice"] == "marin")
        #expect((request["transport"] as? [String: String]) == ["type": "webrtc", "sdp": "offer"])
    }

    @Test func liveRequestUsesPersonaVoice() throws {
        for persona in AvatarPersona.allCases {
            var configuration = LiveConfiguration(instructions: persona.liveInstructions)
            configuration.voice = persona.defaultVoice
            let request = configuration.request(offer: "offer")
            let session = try #require(request["session"] as? [String: Any])
            let audio = try #require(session["audio"] as? [String: Any])
            #expect((audio["output"] as? [String: String])?["voice"] == persona.defaultVoice)
            #expect(session["instructions"] as? String == persona.liveInstructions)
        }
    }

    @Test func transcriptDelegationMuteAndGracefulClose() async throws {
        let transport = FakeTransport()
        let client = GPTLiveClient(service: FakeService(), transport: transport, permission: {})
        client.setMuted(true)
        try await client.connect(configuration: LiveConfiguration(instructions: "Test"))
        #expect(client.state == .connected)
        #expect(!transport.microphoneEnabled)
        client.setMuted(false)
        #expect(transport.microphoneEnabled)
        transport.emit(["type": "session.usage.updated", "usage": ["seconds": 12.0]])
        transport.emit(["type": "session.usage.updated", "usage": ["seconds": 15.0]])
        #expect(client.usageSeconds == 15)
        var requests: [LiveDelegation] = []
        client.onDelegation = { requests.append($0) }
        for (index, delta) in ["please", " smile", " smile"].enumerated() {
            transport.emit(["type": "session.input_transcript.delta", "delta": delta, "start_ms": index * 100, "end_ms": (index + 1) * 100])
        }
        transport.emit(["type": "session.output_transcript.delta", "delta": "Sure", "start_ms": 200, "end_ms": 300])
        let delegation: [String: Any] = ["type": "session.delegation.created", "offset_ms": 300,
            "delegation": ["id": "delegation_1", "target": "client", "type": "delegation"]]
        transport.emit(delegation); transport.emit(delegation)
        #expect(requests.count == 1)
        #expect(requests[0].transcript.filter { $0.speaker == .user }.map(\.delta).joined() == "please smile smile")
        try client.append("Smile applied.", delegationID: "delegation_1", spoken: true)
        #expect(transport.sent.last?["type"] as? String == "session.commentary.append")
        #expect(transport.sent.last?["delegation_id"] as? String == "delegation_1")
        #expect(throws: LiveError.self) { try client.append("Wrong", delegationID: "unknown") }
        try client.appendInstructions("The visible avatar is now Poldo.")
        #expect(transport.sent.last?["type"] as? String == "session.instructions.append")
        #expect(transport.sent.last?["content"] as? String == "The visible avatar is now Poldo.")
        #expect(transport.sent.last?["delegation_id"] is NSNull)
        #expect(throws: LiveError.self) { try client.appendInstructions(String(repeating: "a", count: 481)) }
        client.stop()
        #expect(client.state == .closing)
        #expect(!transport.microphoneEnabled)
        #expect(!transport.closed)
        #expect(transport.sent.last?["type"] as? String == "session.close")
        #expect(throws: LiveError.self) { try client.append("Late result") }
        #expect(throws: LiveError.self) { try client.appendInstructions("Late identity") }
        transport.emit(["type": "error", "error": ["code": "context_injection_incomplete"]])
        #expect(client.state == .closing)
        #expect(!transport.closed)
        transport.emit(["type": "session.closed", "reason": "close_requested", "usage": ["seconds": 15.25]])
        #expect(transport.closed)
        #expect(client.state == .closed)
        #expect(client.finalizationConfirmed)
        #expect(client.usageSeconds == 15.25)
        transport.onFailure?("late disconnect")
        #expect(client.state == .closed)
    }

    @Test func nativeResponsesEventsUseTheConnectedClientAndStopSafely() async throws {
        let transport = FakeTransport()
        let client = GPTLiveClient(service: FakeService(), transport: transport, permission: {})
        var configuration = LiveConfiguration(instructions: "Test")
        configuration.responses = LiveResponsesConfiguration(instructions: "Luna test", tools: [])
        var calls: [String] = []
        client.onResponseToolCall = { call in calls.append(call.id); return "Saved" }
        try await client.connect(configuration: configuration)
        try client.updateResponsesInstructions("The current character is Rei.")
        let update = try #require(transport.sent.last?["session"] as? [String: Any])
        let delegation = try #require(update["delegation"] as? [String: Any])
        #expect((delegation["responses"] as? [String: String])?["instructions"] == "The current character is Rei.")
        transport.emit(["type": "session.delegation.created", "delegation": ["id": "native", "target": "responses"]])
        func event(_ object: [String: Any]) {
            transport.emit(["type": "response.event", "delegation_id": "native", "event": object])
        }
        event(["type": "response.created", "response": ["id": "response"]])
        event(["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "save", "name": "memory_control", "arguments": "{}"]])
        #expect(calls.isEmpty)
        event(["type": "response.completed", "response": ["id": "response", "output": []]])
        for _ in 0..<30 { await Task.yield() }
        #expect(calls == ["save"])
        #expect(transport.sent.last?["type"] as? String == "response.create")
        client.stop()
        event(["type": "response.created", "response": ["id": "late"]])
        event(["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "late", "name": "memory_control", "arguments": "{}"]])
        event(["type": "response.completed", "response": ["id": "late", "output": []]])
        for _ in 0..<30 { await Task.yield() }
        #expect(calls == ["save"])
        #expect(throws: LiveError.self) { try client.updateResponsesInstructions("Late") }
        transport.emit(["type": "session.closed", "usage": ["seconds": 0]])
        #expect(client.state == .closed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_API_TEST"] == "1",
                   "Set LIVE_API_TEST=1 for a billed native Luna web-search and temporary-memory test."))
    func liveAPIResponsesSearchAndMemory() async throws {
        let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: location) }
        let memory = try AvatarMemory(persona: .poldo, directory: location)
        let transport = WebRTCTransport(capturesMicrophone: false)
        let client = GPTLiveClient(service: DirectLiveSessionService(http: OpenAIHTTP(apiKey: try LocalOpenAIKey.load())),
            transport: transport, permission: {})
        var errors: [String] = []
        var cited = false
        client.onError = { errors.append($0) }
        client.onResponseToolCall = { call in
            guard call.name == "memory_control" else { throw LiveError.message("Unexpected test tool") }
            return try AvatarMemoryCommand(arguments: call.arguments).execute(in: memory, confirmed: true)
        }
        client.onBackendMessage = { message in cited = cited || !message.citations.isEmpty }
        var configuration = LiveConfiguration(instructions: "Automated connection test. Stay silent; do not initiate speech. Backend results are inspected by the app.")
        var backend = AvatarDelegation.configuration(context: "Synthetic test. A temporary memory store is used; the test user confirms storing the exact synthetic fact requested.")
        backend.tools = [AvatarDelegation.memoryTool, ["type": "web_search"]]
        configuration.responses = backend
        try await client.connect(configuration: configuration)
        do {
            try transport.send(JSONSerialization.data(withJSONObject: ["type": "response.item.create", "event_id": UUID().uuidString,
                "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Use web_search to find the official Swift programming language website and cite it. Also remember this exact fact using memory_control: Synthetic test user likes Swift. I explicitly confirm saving this test fact."]]]]))
            try transport.send(JSONSerialization.data(withJSONObject: ["type": "response.create", "event_id": UUID().uuidString]))
            let deadline = Date().addingTimeInterval(45)
            while (!cited || memory.entries.isEmpty), errors.isEmpty, client.state == .connected, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            client.stop()
            while client.state == .closing { try? await Task.sleep(nanoseconds: 50_000_000) }
            throw error
        }
        client.stop()
        while client.state == .closing { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(errors.isEmpty)
        #expect(cited)
        #expect(memory.entries.contains { $0.text.contains("Synthetic test user likes Swift") })
        #expect(client.finalizationConfirmed)
    }

    @Test func microphoneWaitsForStartedAndStartupTimesOut() async throws {
        let transport = FakeTransport()
        transport.startedAutomatically = false
        let client = GPTLiveClient(service: FakeService(), transport: transport, permission: {}, readyTimeout: 0.02)
        await #expect(throws: LiveError.self) { try await client.connect(configuration: LiveConfiguration(instructions: "Test")) }
        #expect(!transport.microphoneEnabled)
        #expect(transport.closed)
        if case .failed = client.state {} else { Issue.record("Expected startup failure") }
    }

    @Test func deniedMicrophoneDoesNotCreateSession() async {
        let service = FakeService()
        let transport = FakeTransport()
        let client = GPTLiveClient(service: service, transport: transport, permission: { throw LiveError.message("Denied") })
        await #expect(throws: LiveError.self) { try await client.connect(configuration: LiveConfiguration(instructions: "Test")) }
        #expect(await !service.created)
        #expect(transport.closed)
    }

    @Test func stopDuringHTTPClosesLateSession() async throws {
        let service = FakeService()
        await service.delay(2_000_000_000)
        let transport = FakeTransport()
        let client = GPTLiveClient(service: service, transport: transport, permission: {})
        let connecting = Task { try await client.connect(configuration: LiveConfiguration(instructions: "Test")) }
        while await !service.created { await Task.yield() }
        client.stop()
        _ = try? await connecting.value
        #expect(client.state == .closed)
        #expect(transport.closed)
        #expect(!transport.microphoneEnabled)
        #expect(await service.hangups == ["live_test"])
    }

    @Test func closeTimeoutDoesNotClaimFinalUsage() async throws {
        let transport = FakeTransport()
        let client = GPTLiveClient(service: FakeService(), transport: transport, permission: {}, closeTimeout: 0.01)
        try await client.connect(configuration: LiveConfiguration(instructions: "Test"))
        client.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transport.closed)
        #expect(!client.finalizationConfirmed)
        if case .failed = client.state {} else { Issue.record("Expected unconfirmed-close failure") }
    }

    @Test func credentialsRejectURLsAndPreferExplicitEnvironment() throws {
        #expect(throws: LiveError.self) { try LocalOpenAIKey.load(environment: ["OPENAI_API_KEY": "https://developers.openai.com/"]) }
        #expect(throws: LiveError.self) { try LocalOpenAIKey.load(environment: ["OPENAI_API_KEY": "sk-invalid\nvalue"]) }
        #expect(try LocalOpenAIKey.load(environment: ["OPENAI_API_KEY": " sk-test-only-value\n"]) == "sk-test-only-value")
        let message = LiveError.message("Missing key").localizedDescription
        #expect(!message.contains("sk-"))
    }

    @Test func appendLimitPreservesUnicode() {
        let text = ResponsesDelegationHandler.brief(String(repeating: "🐼", count: 500))
        #expect(text.utf8.count <= 470)
        #expect(!text.contains("�"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_API_TEST"] == "1",
                   "Set LIVE_API_TEST=1 to run the billed, receive-only WebRTC integration check."))
    func liveAPIHandshake() async throws {
        let http = OpenAIHTTP(apiKey: try LocalOpenAIKey.load())
        let client = GPTLiveClient(service: DirectLiveSessionService(http: http),
            transport: WebRTCTransport(capturesMicrophone: false), permission: {})
        client.setMuted(true)
        try await client.connect(configuration: LiveConfiguration(instructions:
            AvatarPersona.poldo.liveInstructions + "\nConnection test: wait silently for the user; do not initiate speech."))
        #expect(client.state == .connected)
        // Closing can reject an in-flight append. The client must still drain session.closed.
        try client.append("Connection test complete.")
        client.stop()
        while client.state == .closing { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(client.state == .closed)
        #expect(client.finalizationConfirmed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_API_TEST"] == "1",
                   "Set LIVE_API_TEST=1 to test the command backend with a synthetic transcript."))
    func liveAPICommandBackend() async throws {
        let http = OpenAIHTTP(apiKey: try LocalOpenAIKey.load())
        let backend = ResponsesDelegationHandler(http: http)
        let request = LiveDelegation(id: "test", offsetMilliseconds: 1000,
            transcript: [LiveTranscript(speaker: .user, delta: "Please smile now.", startMilliseconds: 0, endMilliseconds: 1000)])
        let tools: [[String: Any]] = [["type": "function", "name": "smile", "description": "Apply the Smile motion.",
            "strict": true, "parameters": ["type": "object", "properties": [:], "required": [], "additionalProperties": false]]]
        var applied = false
        let result = try await backend.handle(request, context: "Avatar is neutral; Smile is available.", tools: tools) { name, _ in
            #expect(name == "smile")
            applied = true
            return "Smile applied successfully."
        }
        #expect(applied)
        #expect(!result.isEmpty)
        #expect(result.utf8.count <= 480)
    }
}
