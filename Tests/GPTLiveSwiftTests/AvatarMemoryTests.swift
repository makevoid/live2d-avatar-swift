import Foundation
import Testing
import AvatarBehavior
import GPTLiveSwift

struct AvatarMemoryTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func persistenceDeduplicationDeletionAndPrivatePermissions() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .poldo, directory: directory)
        let url = memory.url
        #expect(memory.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let entry = try memory.remember(" I draw manga 🐼 ")
        #expect(try memory.remember("i draw manga 🐼") == entry)
        let reloaded = try AvatarMemory(persona: .poldo, directory: directory)
        #expect(reloaded.entries == [entry])
        #expect(reloaded.context.contains("I draw manga"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let yaml = try String(contentsOf: url, encoding: .utf8)
        #expect(yaml.contains("character: poldo"))
        #expect(yaml.contains("version: 2"))
        try reloaded.forget(id: entry.id)
        #expect(try AvatarMemory(persona: .poldo, directory: directory).entries.isEmpty)
        _ = try reloaded.remember("My favorite language is Swift.")
        try reloaded.clear()
        #expect(try AvatarMemory(persona: .poldo, directory: directory).entries.isEmpty)
    }

    @Test func writesRequireConfirmationAndDeletesUseExactIDs() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .commander, directory: directory)
        let remember = try AvatarMemoryCommand(arguments: #"{"action":"remember","value":"I like drawing."}"#)
        #expect(try remember.confirmation(in: memory)?.contains("Rei only") == true)
        #expect(throws: LiveError.self) { try remember.execute(in: memory) }
        #expect(memory.entries.isEmpty)
        _ = try remember.execute(in: memory, confirmed: true)
        let list = try AvatarMemoryCommand(arguments: #"{"action":"list","value":""}"#)
        #expect(try list.execute(in: memory).contains("I like drawing."))
        #expect(try list.execute(in: memory).hasPrefix("Rei's saved memory data"))
        #expect(try list.confirmation(in: memory) == nil)
        let ambiguous = try AvatarMemoryCommand(arguments: #"{"action":"forget","value":"drawing"}"#)
        #expect(throws: LiveError.self) { try ambiguous.execute(in: memory, confirmed: true) }
        let entry = try #require(memory.entries.first)
        let forget = try AvatarMemoryCommand(arguments: "{\"action\":\"forget\",\"value\":\"\(entry.id)\"}")
        #expect(try forget.confirmation(in: memory)?.contains(entry.text) == true)
        #expect(throws: LiveError.self) { try forget.execute(in: memory) }
        _ = try forget.execute(in: memory, confirmed: true)
        #expect(memory.entries.isEmpty)
        let clear = try AvatarMemoryCommand(arguments: #"{"action":"clear","value":""}"#)
        #expect(throws: LiveError.self) { try clear.execute(in: memory) }
        #expect(throws: LiveError.self) { try AvatarMemoryCommand(arguments: #"{"action":"shell","value":""}"#) }
        let malformed = try AvatarMemoryCommand(arguments: #"{"action":"list","value":"unexpected"}"#)
        #expect(throws: LiveError.self) { try malformed.execute(in: memory) }
    }

    @Test func reaffirmedCorrectionsBecomeNewestWithoutDuplicatingFacts() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .commander, directory: directory)
        let first = try memory.remember("My employer is Harbor Studio, not its client.")
        let second = try memory.remember("My employer is ClientCo.")
        #expect(memory.entries == [first, second])
        #expect(try memory.remember(first.text) == first)
        let reloaded = try AvatarMemory(persona: .commander, directory: directory)
        #expect(reloaded.entries == [second, first])
        #expect(reloaded.recallContext.contains("ordered oldest to newest"))
        #expect(reloaded.recallContext.contains("latest saved correction wins"))
    }

    @Test func corruptionAndWriteFailuresNeverEraseFacts() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .poldo, directory: directory)
        let url = memory.url
        _ = try memory.remember("Keep this fact.")
        let original = memory.entries
        #expect(throws: LiveError.self) { try memory.remember("   ") }
        #expect(throws: LiveError.self) { try memory.remember(String(repeating: "🐼", count: 251)) }
        #expect(throws: LiveError.self) { try memory.forget(id: UUID()) }
        #expect(memory.entries == original)
        try Data("entries: [".utf8).write(to: url)
        #expect(throws: LiveError.self) { try AvatarMemory(persona: .poldo, directory: directory) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "entries: [")
        let unwritable = try AvatarMemory(persona: .poldo, directory: url)
        #expect(throws: (any Error).self) { try unwritable.remember("Must not claim success") }
        #expect(unwritable.entries.isEmpty)
    }

    @Test func capacityDoesNotSilentlyEvictOlderFacts() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .poldo, directory: directory)
        for index in 0..<50 { try memory.remember("Fact \(index)") }
        #expect(throws: LiveError.self) { try memory.remember("One too many") }
        #expect(try AvatarMemory(persona: .poldo, directory: directory).entries.count == 50)
        #expect(memory.entries.first?.text == "Fact 0")
    }

    @Test func charactersCannotRecallForgetOrClearEachOthersFacts() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let poldo = try AvatarMemory(persona: .poldo, directory: directory)
        let rei = try AvatarMemory(persona: .commander, directory: directory)
        #expect(poldo.url.lastPathComponent == "poldo.yaml")
        #expect(rei.url.lastPathComponent == "rei.yaml")
        let poldoFact = try poldo.remember("Poldo-only preference")
        let reiFact = try rei.remember("Rei-only preference")
        let list = try AvatarMemoryCommand(arguments: #"{"action":"list","value":""}"#)
        #expect(!(try list.execute(in: poldo)).contains(reiFact.text))
        #expect(!(try list.execute(in: rei)).contains(poldoFact.text))
        let forget = try AvatarMemoryCommand(arguments: "{\"action\":\"forget\",\"value\":\"\(poldoFact.id)\"}")
        #expect(throws: LiveError.self) { try forget.execute(in: rei, confirmed: true) }
        let originalRei = try Data(contentsOf: rei.url)
        _ = try forget.execute(in: poldo, confirmed: true)
        try poldo.remember("Another Poldo fact")
        let clear = try AvatarMemoryCommand(arguments: #"{"action":"clear","value":""}"#)
        #expect(try clear.confirmation(in: poldo)?.contains("Poldo only") == true)
        _ = try clear.execute(in: poldo, confirmed: true)
        #expect(try AvatarMemory(persona: .poldo, directory: directory).entries.isEmpty)
        #expect(try AvatarMemory(persona: .commander, directory: directory).entries == [reiFact])
        #expect(try Data(contentsOf: rei.url) == originalRei)
    }

    @Test func yamlRoundTripsSpecialStringsAndReadsHandEditedBlocks() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .commander, directory: directory)
        for value in ["true", "null", "2026-10-06", "123", "Swift: #1\n日本語 🐼\n\"quoted\" \\path", "- list? &anchor *alias"] {
            try memory.remember(value)
        }
        #expect(try AvatarMemory(persona: .commander, directory: directory).entries == memory.entries)
        let identifier = UUID()
        let yaml = """
        # Hand-edited Rei facts
        version: 2
        character: rei
        entries:
          - id: \(identifier)
            text: |-
              Favorite tools:
              Swift and 漫画 # notes
        """
        try Data(yaml.utf8).write(to: memory.url)
        let reloaded = try AvatarMemory(persona: .commander, directory: directory)
        #expect(reloaded.entries.first?.id == identifier)
        #expect(reloaded.entries.first?.text == "Favorite tools:\nSwift and 漫画 # notes")
    }

    @Test func mismatchedOwnersVersionsDuplicateIDsAndOversizeFilesFailClosed() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = try AvatarMemory(persona: .poldo, directory: directory)
        try memory.clear()
        let entry: [String: Any] = ["id": UUID().uuidString, "text": "A valid fact"]
        let invalid: [[String: Any]] = [
            ["version": 2, "character": "rei", "entries": []],
            ["version": 99, "character": "poldo", "entries": []],
            ["version": 2, "character": "poldo", "entries": [entry, entry]],
            ["version": 2, "character": "poldo", "entries": [["id": UUID().uuidString, "text": " "]]],
            ["version": 2, "character": "poldo", "entries": [["id": UUID().uuidString, "text": String(repeating: "a", count: 501)]]]
        ]
        var fixtures = try invalid.map { try JSONSerialization.data(withJSONObject: $0) }
        fixtures.append(Data(repeating: 32, count: 65_537))
        for data in fixtures {
            try data.write(to: memory.url)
            #expect(throws: LiveError.self) { try AvatarMemory(persona: .poldo, directory: directory) }
            #expect(try Data(contentsOf: memory.url) == data)
        }
    }

    @Test func legacySharedFactsImportOnceIntoIndependentFilesWithoutDataLoss() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1,
            "entries": [["id": identifier.uuidString, "text": "Previously shared fact"]]])
        let legacyURL = directory.appendingPathComponent("memories.json")
        try data.write(to: legacyURL)
        let poldo = try AvatarMemory(persona: .poldo, directory: directory)
        let rei = try AvatarMemory(persona: .commander, directory: directory)
        #expect(poldo.entries.first?.id == identifier)
        #expect(rei.entries == poldo.entries)
        #expect(FileManager.default.fileExists(atPath: poldo.url.path))
        #expect(FileManager.default.fileExists(atPath: rei.url.path))
        try poldo.clear()
        #expect(try AvatarMemory(persona: .poldo, directory: directory).entries.isEmpty)
        #expect(try AvatarMemory(persona: .commander, directory: directory).entries == rei.entries)
        #expect(try Data(contentsOf: legacyURL) == data)
    }

    @Test func invalidLegacyFileIsPreservedAndExistingYamlWins() throws {
        let directory = location()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rei = try AvatarMemory(persona: .commander, directory: directory)
        try rei.remember("Rei's fact")
        let legacyURL = directory.appendingPathComponent("memories.json")
        let invalid = Data("corrupt legacy".utf8)
        try invalid.write(to: legacyURL)
        #expect(try AvatarMemory(persona: .commander, directory: directory).entries == rei.entries)
        #expect(throws: LiveError.self) { try AvatarMemory(persona: .poldo, directory: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("poldo.yaml").path))
        #expect(try Data(contentsOf: legacyURL) == invalid)
    }
}
