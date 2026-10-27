import Foundation

public enum AvatarEmotion: String, CaseIterable, Codable {
    case happy, excited, playful, sad, hurt, apologetic, curious, surprised, neutral

    public var title: String { rawValue.capitalized }
    public var voiceDirection: String {
        switch self {
        case .happy: return "Sound sunny, warm and bubbly, with a smile in your voice."
        case .excited: return "Sound delighted and animated, with lively melodic rhythm; keep a comfortable volume."
        case .playful: return "Sound gently teasing and playful; a small natural chuckle fits."
        case .sad: return "Sound soft, slower and caring. Let sad news breathe; no cheerful laughter."
        case .hurt: return "Sound briefly hurt and bashful, then composed and kind. Never seek reassurance or guilt-trip."
        case .apologetic: return "Sound sincerely sorry, gentle and accountable. Acknowledge the mistake and focus on fixing it."
        case .curious: return "Sound bright and inquisitive, with a thoughtful pause and interested rising intonation."
        case .surprised: return "Sound briefly amazed, with a light natural gasp if appropriate, then settle."
        case .neutral: return "Sound attentive, calm and natural."
        }
    }
}

/// All values are transient: neutral face targets, additive body gestures and blink multipliers.
/// Runtime filters these against the actual compiled model, which differs substantially by avatar.
public struct EmotionPose {
    public var values: [String: Double] = [:]
    public var offsets: [String: Double] = [:]
    public var multipliers: [String: Double] = [:]

    public init() {}

    public static func sample(_ emotion: AvatarEmotion, seconds: Double, creature: Bool) -> EmotionPose {
        let t = max(0, seconds)
        var pose = EmotionPose()
        var mouth = 1.0, browY = 0.12, browAngle = 0.0, browForm = 0.0
        var cheek = 0.18, eyeSmile = 0.25, eyeScale = 1.0
        var pitch = 0.0, roll = 0.0, yaw = 0.0, body = 0.0
        let entry = exp(-t * 0.8)
        switch emotion {
        case .happy:
            roll = sin(t * 1.5) * 1.5
            pitch = sin(t * 2.2) * 1.2
        case .excited:
            browY = 0.5; cheek = 0.42; eyeSmile = 0.7; eyeScale = 0.85
            pitch = 2 + sin(t * 6) * (1.2 + 3 * entry)
            roll = sin(t * 4.5) * (1.5 + 3 * entry)
            body = sin(t * 4.5) * 1.2
        case .playful:
            cheek = 0.35; eyeSmile = 0.8; roll = 5 + sin(t * 2) * 1.8
            yaw = sin(t * 1.8) * 2
            // One wink on entry; repeated selection explicitly replays it.
            let wink = max(0, 1 - abs(t - 0.65) / 0.28)
            pose.multipliers["ParamEyeLOpen"] = 1 - wink
        case .sad:
            mouth = -0.9; browY = -0.45; browAngle = -0.65; browForm = -0.7
            cheek = 0.05; eyeSmile = 0; eyeScale = 0.72
            pitch = -7; roll = -3 + sin(t * 0.8) * 0.5
        case .hurt:
            mouth = -0.8; browY = -0.15; browAngle = -0.75; browForm = -0.75
            cheek = 0.32; eyeSmile = 0; eyeScale = 0.8
            pitch = -4 + entry * 3; yaw = -5; roll = 4
        case .apologetic:
            mouth = -0.4; browY = -0.3; browAngle = -0.5; browForm = -0.5
            cheek = 0.2; eyeSmile = 0; eyeScale = 0.82
            pitch = -3 - 6 * max(0, sin(min(t / 1.8, 1) * .pi))
            roll = -2
        case .curious:
            mouth = 0.45; browY = 0.4; cheek = 0.12; eyeSmile = 0
            roll = 7; yaw = 2 + sin(t * 1.2); pitch = 1.5
        case .surprised:
            mouth = 0; browY = 0.8; cheek = 0.12; eyeSmile = 0
            pitch = 2 + 4 * entry; roll = -2 * entry
        case .neutral:
            mouth = 0; browY = 0; cheek = 0; eyeSmile = 0
        }
        pose.values = ["ParamMouthForm": mouth, "ParamCheek": cheek,
            "ParamBrowLY": browY, "ParamBrowRY": browY,
            "ParamBrowLAngle": browAngle, "ParamBrowRAngle": browAngle,
            "ParamBrowLForm": browForm, "ParamBrowRForm": browForm,
            "ParamEyeLSmile": eyeSmile, "ParamEyeRSmile": eyeSmile]
        if emotion == .curious { pose.values["ParamBrowRY"] = 0.65 }
        if creature {
            // Authored expression switches: Heart, Angy and Cry. Hand Up stays manual.
            pose.values["Param"] = emotion == .playful ? 30 : 0
            pose.values["Param2"] = 0
            pose.values["Param3"] = emotion == .sad ? 30 : 0
        } else {
            // Character's authored tear overlay, without changing coat/hat/hand accessories.
            pose.values["Param38"] = emotion == .sad ? 1 : 0
        }
        pose.offsets = ["ParamAngleX": yaw, "ParamAngleY": pitch, "ParamAngleZ": roll,
                        "ParamBodyAngleX": body, "ParamBodyAngleZ": body * 0.5]
        pose.multipliers["ParamEyeLOpen", default: 1] *= eyeScale
        pose.multipliers["ParamEyeROpen"] = eyeScale
        return pose
    }
}
