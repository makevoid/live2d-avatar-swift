import AVFoundation

public enum LiveAudioSession {
    public static func requestMicrophone() async throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw LiveError.message("No microphone is available. Connect an input device and start voice again.")
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else {
            throw LiveError.message("Enable Live2D Avatar in System Settings → Privacy & Security → Microphone, then try again.")
        }
    }
}
