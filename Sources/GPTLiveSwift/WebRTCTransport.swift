import Foundation
@preconcurrency import WebRTC

@MainActor
protocol LiveTransport: AnyObject {
    var onMessage: ((Data) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onAudioLevel: ((Double) -> Void)? { get set }
    func offer() async throws -> String
    func accept(answer: String) async throws
    func send(_ data: Data) throws
    func setMicrophone(enabled: Bool)
    func close()
}

/// WebRTC owns capture, echo cancellation, Opus, jitter buffering and speaker playback.
/// Delegate callbacks cross onto the main actor before touching session or UI state.
@MainActor
final class WebRTCTransport: NSObject, LiveTransport {
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        RTCSetMinDebugLogLevel(.none)
        return factory
    }()
    private var peer: RTCPeerConnection?
    private var events: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var meter: Task<Void, Never>?
    private var energy: Double = 0
    private var duration: Double = 0
    private let capturesMicrophone: Bool

    init(capturesMicrophone: Bool = true) {
        self.capturesMicrophone = capturesMicrophone
        super.init()
    }

    func offer() async throws -> String {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw LiveError.message("Could not create the WebRTC connection.")
        }
        peer = connection
        if capturesMicrophone {
            let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
                optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"]))
            let track = Self.factory.audioTrack(with: source, trackId: "microphone")
            // Negotiating a track does not grant permission to transmit until session.started.
            track.isEnabled = false
            microphone = track
            connection.add(track, streamIds: ["avatar-voice"])
        } else {
            // Receive-only integration tests never create a microphone track or ask for permission.
            let transceiver = RTCRtpTransceiverInit()
            transceiver.direction = .recvOnly
            connection.addTransceiver(of: .audio, init: transceiver)
        }
        guard let channel = connection.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()) else {
            throw LiveError.message("Could not create the Live event channel.")
        }
        events = channel
        channel.delegate = self
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? LiveError.message("WebRTC did not produce an offer.")) }
            }
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // No trickle ICE endpoint: include all candidates in the POSTed SDP.
        let deadline = Date().addingTimeInterval(10)
        while connection.iceGatheringState != .complete {
            try Task.checkCancellation()
            guard peer === connection else { throw CancellationError() }
            guard Date() < deadline else { throw LiveError.message("WebRTC timed out gathering network candidates.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let sdp = connection.localDescription?.sdp else { throw LiveError.message("WebRTC offer is missing.") }
        return sdp
    }

    func accept(answer: String) async throws {
        guard let peer else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        meter = Task { [weak self] in
            while !Task.isCancelled {
                self?.readAudioLevel()
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            }
        }
    }

    func send(_ data: Data) throws {
        guard let events, events.readyState == .open,
              events.sendData(RTCDataBuffer(data: data, isBinary: false)) else {
            throw LiveError.message("The Live event channel is not ready.")
        }
    }

    func setMicrophone(enabled: Bool) { microphone?.isEnabled = enabled }

    func close() {
        meter?.cancel(); meter = nil
        microphone?.isEnabled = false
        events?.delegate = nil
        events?.close(); events = nil
        peer?.delegate = nil
        peer?.close(); peer = nil
        microphone = nil
        onAudioLevel?(0)
    }

    private func readAudioLevel() {
        guard let connection = peer else { return }
        connection.statistics { [weak self, weak connection] report in
            Task { @MainActor in
                guard let self, let connection, self.peer === connection else { return }
                var level = 0.0
                for stats in report.statistics.values where stats.type == "inbound-rtp" {
                    let values = stats.values
                    guard (values["kind"] as? String ?? values["mediaType"] as? String) == "audio" else { continue }
                    if let sample = values["audioLevel"] as? NSNumber { level = sample.doubleValue }
                    else if let energy = values["totalAudioEnergy"] as? NSNumber,
                            let duration = values["totalSamplesDuration"] as? NSNumber {
                        let delta = duration.doubleValue - self.duration
                        if delta > 0 { level = sqrt(max(0, energy.doubleValue - self.energy) / delta) }
                        self.energy = energy.doubleValue; self.duration = duration.doubleValue
                    }
                }
                self.onAudioLevel?(min(1, max(0, level * 5)))
            }
        }
    }
}

extension WebRTCTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.events === dataChannel else { return }
            if dataChannel.readyState == .closed { self.onFailure?("Voice disconnected before finalization.") }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        let data = buffer.data
        Task { @MainActor [weak self] in
            guard let self, self.events === dataChannel else { return }
            self.onMessage?(data)
        }
    }
}

extension WebRTCTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            if newState == .failed { self.onFailure?("WebRTC could not maintain the audio connection. Start voice again.") }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
