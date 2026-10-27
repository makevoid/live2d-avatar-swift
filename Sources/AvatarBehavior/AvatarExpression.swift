import Foundation

/// Human-readable names for visually reviewed, authored expression assets.
/// IDs remain unchanged in the original model and Cubism manifest.
public struct AvatarExpression: Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let isTransient: Bool

    public init(id: String, name: String, description: String, isTransient: Bool = false) {
        self.id = id; self.name = name; self.description = description; self.isTransient = isTransient
    }

    public var instruction: String { "\(name): \(description)" }
}

extension AvatarPersona {
    public var defaultExpressionDescription: String {
        switch self {
        case .haru:
            return "The authored neutral Haru sample pose. Use only expressions listed in current app state."
        case .commander:
            return "Default look: black-and-orange coat on, gray tactical top, goggles up on the head, no cap, arms down and no face effects. Bear ears are hidden."
        case .poldo:
            return "Default look: fluffy red panda with paws down, no hearts, tears or anger mark, standing in the mountain meadow."
        }
    }

    public var expressions: [AvatarExpression] {
        switch self {
        case .haru:
            return []
        case .commander:
            return [
                .init(id: "1", name: "Coat Off", description: "Removes the coat; gray tactical top and goggles up. For a casual look."),
                .init(id: "2", name: "Cap", description: "White officer cap with gold trim; coat on, goggles above the eyes. For commander roleplay."),
                .init(id: "3", name: "Angry", description: "Red comic anger marks by the forehead and cheek. For playful annoyance.", isTransient: true),
                .init(id: "4", name: "Tears", description: "Watery eyes and tears on the cheeks. For sadness or a touching moment.", isTransient: true),
                .init(id: "5", name: "Heart Eyes", description: "Heart-shaped pupils and strong blush. For affection or adoration.", isTransient: true),
                .init(id: "6", name: "Star Eyes", description: "Bright star-shaped eye highlights. For excitement or amazement.", isTransient: true),
                .init(id: "7", name: "Gloom", description: "Dark shadow across the upper face. For dismay or comic embarrassment.", isTransient: true),
                .init(id: "8", name: "Arms Crossed", description: "Folds both arms across the chest, coat on. For confidence or mock skepticism.", isTransient: true),
                .init(id: "9", name: "Ears Off", description: "Authored bear-ear hiding switch; ears are already hidden in this app, so it adds no visible effect."),
                .init(id: "mujing", name: "Goggles Down", description: "Lowers goggles over the eyes, coat on and arms down. For an action-ready look."),
                .init(id: "mujing2", name: "Goggles Salute", description: "Coat off, goggles over the eyes, one hand touching the goggles in a salute-like pose.", isTransient: true)
            ]
        case .poldo:
            return [
                .init(id: "Angy", name: "Angry", description: "Red comic anger mark on the forehead. For playful annoyance.", isTransient: true),
                .init(id: "Cry", name: "Tears", description: "Small blue tears under both eyes. For sadness or a touching moment.", isTransient: true),
                .init(id: "Hand Up", name: "Paws Up", description: "Raises both paws with paw pads facing forward. For greetings or celebration.", isTransient: true),
                .init(id: "Heart", name: "Hearts", description: "Pink hearts beside the face. For affection or thanks.", isTransient: true)
            ]
        }
    }

    public var expressionInstructions: String {
        (["Authored expressions for \(name). Neutral: \(defaultExpressionDescription)"] +
            expressions.map(\.instruction)).joined(separator: "\n")
    }

    /// Each update fits the client's conservative 480-byte instruction limit.
    public var expressionInstructionUpdates: [String] {
        ["Current avatar \(name). Use only this avatar's expression catalog; previous avatars' presets no longer apply. Neutral: \(defaultExpressionDescription)"] +
            expressions.map { "\(name) expression \($0.instruction)" }
    }
}
