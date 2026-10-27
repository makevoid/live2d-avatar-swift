import Foundation
import GPTLiveSwift

/// A local display history. It neither requests transcription nor changes model context.
public struct ConversationTranscript {
    public struct Entry: Equatable {
        public let speaker: LiveTranscript.Speaker
        public let name: String
        public let startMilliseconds: Int
        public fileprivate(set) var endMilliseconds: Int
        public fileprivate(set) var text: String
        public var citations: [LiveCitation] = []
    }

    public private(set) var entries: [Entry] = []
    public private(set) var wasTrimmed = false
    private let maximumEntries: Int
    private let maximumCharacters: Int

    public init(maximumEntries: Int = 300, maximumCharacters: Int = 60_000) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumCharacters = max(1, maximumCharacters)
    }

    public mutating func append(_ fragment: LiveTranscript, characterName: String) {
        guard !fragment.delta.isEmpty else { return }
        let name = fragment.speaker == .user ? "You" : characterName
        // Live has timestamped deltas rather than turn IDs. Join nearby chunks from
        // each speaker even when the other speaker's simultaneous chunks interleave.
        if let index = entries.lastIndex(where: { $0.speaker == fragment.speaker }),
           entries[index].name == name,
           fragment.startMilliseconds >= entries[index].startMilliseconds,
           Double(fragment.startMilliseconds) - Double(entries[index].endMilliseconds) <= 1_500 {
            entries[index].text += fragment.delta
            entries[index].endMilliseconds = max(entries[index].endMilliseconds, fragment.endMilliseconds)
        } else {
            let entry = Entry(speaker: fragment.speaker, name: name,
                startMilliseconds: fragment.startMilliseconds,
                endMilliseconds: fragment.endMilliseconds, text: fragment.delta)
            // Input and output transcript events can arrive in different orders.
            let index = entries.firstIndex { $0.startMilliseconds > fragment.startMilliseconds } ?? entries.endIndex
            entries.insert(entry, at: index)
        }
        trim()
    }

    public mutating func appendBackend(_ message: LiveBackendMessage, characterName: String, milliseconds: Int) {
        entries.append(Entry(speaker: .assistant, name: characterName + " · Web sources",
            startMilliseconds: milliseconds, endMilliseconds: milliseconds, text: message.text,
            citations: message.citations))
        trim()
    }

    private mutating func trim() {
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
            wasTrimmed = true
        }
        var excess = entries.reduce(0) { $0 + $1.text.count } - maximumCharacters
        while excess > 0, !entries.isEmpty {
            let count = entries[0].text.count
            if count <= excess || !entries[0].citations.isEmpty { entries.removeFirst(); excess -= count }
            else { entries[0].text = String(entries[0].text.dropFirst(excess)); excess = 0 }
            wasTrimmed = true
        }
    }

    public mutating func clear() {
        entries.removeAll()
        wasTrimmed = false
    }
}
