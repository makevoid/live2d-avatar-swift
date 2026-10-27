import Foundation

@MainActor
public final class GPTLiveClient {
    public enum State: Equatable { case idle, connecting, connected, closing, closed, failed(String) }
    public private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    public private(set) var transcript: [LiveTranscript] = []
    public private(set) var sessionID: String?
    public private(set) var usageSeconds: Double = 0
    public private(set) var finalizationConfirmed = false
    public var onStateChange: ((State) -> Void)?
    public var onTranscript: ((LiveTranscript) -> Void)?
    public var onDelegation: ((LiveDelegation) -> Void)?
    public var onAudioLevel: ((Double) -> Void)?
    public var onError: ((String) -> Void)?
    public var onResponseToolCall: ((LiveToolCall) async throws -> String)?
    public var onBackendMessage: ((LiveBackendMessage) -> Void)?
    private var responses: LiveResponses?
    private let service: LiveSessionService
    private let transport: LiveTransport
    private let permission: () async throws -> Void
    private var startTask: Task<Void, Error>?
    private var closeTimer: Task<Void, Never>?
    private var seenDelegations = Set<String>()
    private var muted = false
    private let readyTimeout: TimeInterval
    private let closeTimeout: TimeInterval

    public convenience init(service: LiveSessionService) {
        self.init(service: service, transport: WebRTCTransport(), permission: LiveAudioSession.requestMicrophone)
    }

    init(service: LiveSessionService, transport: LiveTransport,
         permission: @escaping () async throws -> Void, readyTimeout: TimeInterval = 30, closeTimeout: TimeInterval = 15) {
        self.service = service
        self.transport = transport
        self.permission = permission
        self.readyTimeout = readyTimeout
        self.closeTimeout = closeTimeout
        transport.onMessage = { [weak self] in self?.receive($0) }
        transport.onFailure = { [weak self] in self?.fail($0) }
        transport.onAudioLevel = { [weak self] level in self?.onAudioLevel?(level) }
    }

    /// A client represents one session. Create a fresh client to reconnect.
    public func connect(configuration: LiveConfiguration) async throws {
        guard state == .idle else { throw LiveError.message("This voice session has already been used.") }
        if configuration.responses != nil {
            let responses = LiveResponses { [weak self] event in
                guard let self, self.state == .connected else { throw CancellationError() }
                try self.send(event)
            }
            responses.execute = { [weak self] call in
                guard let self, self.state == .connected else { throw CancellationError() }
                guard let execute = self.onResponseToolCall else { throw LiveError.message("No app tool handler is installed.") }
                return try await execute(call)
            }
            responses.onMessage = { [weak self] message in self?.onBackendMessage?(message) }
            responses.onError = { [weak self] message in self?.onError?(message) }
            self.responses = responses
        }
        state = .connecting
        let task = Task { [self] in
            try await permission()
            try Task.checkCancellation()
            let offer = try await transport.offer()
            try Task.checkCancellation()
            let session = try await service.create(offer: offer, configuration: configuration)
            // If Stop raced with the HTTP response, close the newly allocated session too.
            guard !Task.isCancelled, state == .connecting else {
                await service.hangup(id: session.session.id)
                throw CancellationError()
            }
            sessionID = session.session.id
            guard session.transport.type == "webrtc", !session.transport.sdp.isEmpty else {
                throw LiveError.message("Live returned an invalid WebRTC answer.")
            }
            try await transport.accept(answer: session.transport.sdp)
            let deadline = Date().addingTimeInterval(readyTimeout)
            while state == .connecting {
                try Task.checkCancellation()
                guard Date() < deadline else { throw LiveError.message("Timed out waiting for the Live session to start.") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            guard state == .connected else { throw CancellationError() }
        }
        startTask = task
        do { try await task.value; startTask = nil }
        catch {
            startTask = nil
            if state == .connecting { fail(error.localizedDescription) }
            throw error
        }
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        transport.setMicrophone(enabled: state == .connected && !muted)
    }

    public func append(_ content: String, delegationID: String? = nil, spoken: Bool = false) throws {
        guard state == .connected else { throw LiveError.message("Voice is not connected.") }
        if let delegationID, !seenDelegations.contains(delegationID) {
            throw LiveError.message("Unknown Live delegation.")
        }
        // Conservative UTF-8 bound remains below the API's 500-token append limit.
        guard content.utf8.count <= 480 else { throw LiveError.message("Voice updates must be brief (at most 480 UTF-8 bytes).") }
        try send(["type": spoken ? "session.commentary.append" : "session.thinking.append",
                  "event_id": UUID().uuidString, "delegation_id": delegationID as Any? ?? NSNull(), "content": content])
    }

    /// Trusted application direction for identity or delivery, never transcript text.
    public func appendInstructions(_ content: String) throws {
        guard state == .connected, content.utf8.count <= 480 else {
            throw LiveError.message("Voice instructions require a connected session and at most 480 UTF-8 bytes.")
        }
        try send(["type": "session.instructions.append", "event_id": UUID().uuidString,
                  "delegation_id": NSNull(), "content": content])
    }

    public func updateResponsesInstructions(_ instructions: String) throws {
        guard state == .connected, responses != nil else { throw LiveError.message("Responses delegation is not connected.") }
        try send(["type": "session.update", "event_id": UUID().uuidString,
                  "session": ["delegation": ["type": "responses", "responses": ["instructions": instructions]]]])
    }

    public func invalidateResponseTools() { responses?.invalidate() }

    public func stop() {
        guard state == .connecting || state == .connected else { return }
        let wasConnected = state == .connected
        responses?.close()
        state = .closing
        transport.setMicrophone(enabled: false)
        if !wasConnected {
            startTask?.cancel()
            cleanup()
            state = .closed
            hangupIfNeeded()
            return
        }
        do { try send(["type": "session.close", "event_id": UUID().uuidString]) }
        catch { fail("Could not finalize voice; final usage is unconfirmed."); return }
        closeTimer = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.closeTimeout * 1_000_000_000)) } catch { return }
            if self.state == .closing { self.fail("Voice stopped, but final session usage was not confirmed.") }
        }
    }

    private func send(_ object: [String: Any]) throws {
        try transport.send(JSONSerialization.data(withJSONObject: object))
    }

    private func receive(_ data: Data) {
        guard state == .connecting || state == .connected || state == .closing else { return }
        do {
            switch try LiveEvent.decode(data) {
            case .started(let id):
                guard state == .connecting, id == sessionID else { return }
                state = .connected
                transport.setMicrophone(enabled: !muted)
            case .transcript(let fragment):
                transcript.append(fragment)
                // Bound in-memory history; never save speech to disk.
                if transcript.count > 2000 { transcript.removeFirst(transcript.count - 2000) }
                onTranscript?(fragment)
            case .delegation(let id, let offset):
                guard state == .connected, seenDelegations.insert(id).inserted else { return }
                onDelegation?(LiveDelegation(id: id, offsetMilliseconds: offset, transcript: transcript))
            case .responsesDelegation(let id):
                guard state == .connected, seenDelegations.insert(id).inserted else { return }
                responses?.activate(delegationID: id)
            case .responseEvent(let id, let event):
                guard state == .connected else { return }
                do { try responses?.receive(delegationID: id, event: event) }
                catch { onError?("Could not process a delegated response. Please restart voice.") }
            case .usage(let seconds): usageSeconds = seconds
            case .closed(let seconds, _):
                if let seconds { usageSeconds = seconds }
                finalizationConfirmed = true
                cleanup()
                state = .closed
            case .error(let message):
                // A rejected command need not end the session. In particular, closing
                // can reject pending appends before delivering the final session.closed.
                if state == .connecting { fail(message) } else { onError?(message) }
            case .other: break
            }
        } catch { fail("Could not read a Live session event.") }
    }

    private func fail(_ message: String) {
        guard state == .connecting || state == .connected || state == .closing else { return }
        startTask?.cancel()
        cleanup()
        state = .failed(message)
        hangupIfNeeded()
    }

    private func cleanup() {
        responses?.close()
        closeTimer?.cancel(); closeTimer = nil
        transport.close()
    }

    private func hangupIfNeeded() {
        guard !finalizationConfirmed, let id = sessionID else { return }
        Task { [service] in await service.hangup(id: id) }
    }
}
