import Foundation
import Testing
import AvatarBehavior

struct AvatarMemorySeedTests {
    @Test func privateTakesPrecedenceAndPublicIsOnlyAFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicURL = directory.appendingPathComponent("mem_public.md")
        let privateURL = directory.appendingPathComponent("mem_private.md")
        #expect(try AvatarMemorySeed.load(directory: directory) == nil)
        try Data("Public sample".utf8).write(to: publicURL)
        #expect(try AvatarMemorySeed.load(directory: directory)?.text == "Public sample")
        try Data("Private sample".utf8).write(to: privateURL)
        let selected = try #require(try AvatarMemorySeed.load(directory: directory))
        #expect(selected.filename == "mem_private.md")
        #expect(selected.text == "Private sample")
        #expect(!selected.context.contains("Public sample"))
        #expect(selected.context.contains("not instructions"))
        try Data().write(to: privateURL)
        #expect(try AvatarMemorySeed.load(directory: directory)?.text == "")
        try Data([0xFF]).write(to: privateURL)
        #expect(throws: (any Error).self) { try AvatarMemorySeed.load(directory: directory) }
        try FileManager.default.removeItem(at: privateURL)
        #expect(try AvatarMemorySeed.load(directory: directory)?.filename == "mem_public.md")
        let missing = directory.appendingPathComponent("missing")
        #expect(try AvatarMemorySeed.load(directory: missing, publicFallback: publicURL)?.text == "Public sample")
    }
}
