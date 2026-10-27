import Foundation
import GPTLiveSwift

public struct AvatarMemoryCommand: Decodable {
    public enum Action: String, Decodable { case list, remember, forget, clear }
    public let action: Action
    public let value: String

    public init(arguments: String) throws {
        guard let data = arguments.data(using: .utf8), data.count <= 8192,
              let command = try? JSONDecoder().decode(Self.self, from: data) else {
            throw LiveError.message("Unknown or malformed memory command.")
        }
        self = command
    }

    public func confirmation(in memory: AvatarMemory) throws -> String? {
        switch action {
        case .list, .clear:
            guard value.isEmpty else { throw LiveError.message("List and clear require an empty value.") }
            return action == .list ? nil : "Delete all \(memory.entries.count) explicitly saved facts for \(memory.persona.name) only? The other character's memories and read-only reference profile will not change."
        case .remember:
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 500, text.utf8.count <= 1000 else {
                throw LiveError.message("A memory must contain 1–500 characters and at most 1,000 UTF-8 bytes.")
            }
            return "Save this fact for \(memory.persona.name) only?\n\n\(text)"
        case .forget:
            guard let id = UUID(uuidString: value), let entry = memory.entries.first(where: { $0.id == id }) else {
                throw LiveError.message("Unknown memory ID. List memories before forgetting a fact.")
            }
            return "Delete this saved fact for \(memory.persona.name) only?\n\n\(entry.text)"
        }
    }

    public func execute(in memory: AvatarMemory, confirmed: Bool = false) throws -> String {
        if try confirmation(in: memory) != nil, !confirmed {
            throw LiveError.message("Memory changes require the user's confirmation in the app.")
        }
        switch action {
        case .list: return memory.recallContext
        case .remember:
            let entry = try memory.remember(value)
            return "Memory saved for \(memory.persona.name) only. ID: \(entry.id.uuidString)."
        case .forget:
            guard let id = UUID(uuidString: value) else { throw LiveError.message("Invalid memory ID.") }
            try memory.forget(id: id)
            return "Deleted \(memory.persona.name)'s saved memory. The other character's memories are unchanged."
        case .clear:
            try memory.clear()
            return "Deleted all explicitly saved facts for \(memory.persona.name) only. The other character's memories and read-only reference profile are unchanged. Start a fresh voice session to clear existing conversational context too."
        }
    }
}
