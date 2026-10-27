import Foundation
import Testing
import AvatarBehavior
import GPTLiveSwift

struct ConversationTranscriptTests {
    @Test func overlappingSpeakersPreserveWordsSpacingAndNames() {
        var transcript = ConversationTranscript()
        transcript.append(fragment(.user, "Hello", 0, 200), characterName: "Poldo")
        transcript.append(fragment(.assistant, "I'm", 100, 300), characterName: "Poldo")
        transcript.append(fragment(.user, " Poldo!", 200, 400), characterName: "Poldo")
        transcript.append(fragment(.assistant, " very", 300, 500), characterName: "Poldo")
        transcript.append(fragment(.assistant, " very happy 🐾", 500, 700), characterName: "Poldo")
        #expect(transcript.entries.map(\.text) == ["Hello Poldo!", "I'm very very happy 🐾"])
        #expect(transcript.entries.map(\.name) == ["You", "Poldo"])
        transcript.append(fragment(.assistant, "I'm Commander now.", 800, 1000), characterName: "Commander")
        #expect(transcript.entries.map(\.name) == ["You", "Poldo", "Commander"])
        transcript.append(fragment(.assistant, "A new turn.", 4000, 4500), characterName: "Commander")
        #expect(transcript.entries.count == 4)
    }

    @Test func lateArrivalAndBoundedUnicodeHistory() {
        var transcript = ConversationTranscript(maximumEntries: 2, maximumCharacters: 8)
        transcript.append(fragment(.assistant, "Hi", 200, 300), characterName: "Poldo")
        transcript.append(fragment(.user, "Hey", 0, 100), characterName: "Poldo")
        #expect(transcript.entries.map(\.name) == ["You", "Poldo"])
        transcript.append(fragment(.assistant, "👨‍👩‍👧‍👦🐼12345678", 3000, 4000), characterName: "Poldo")
        #expect(transcript.entries.map(\.text) == ["12345678"])
        #expect(transcript.wasTrimmed)
        transcript.clear()
        #expect(transcript.entries.isEmpty)
        #expect(!transcript.wasTrimmed)
        transcript.append(fragment(.user, "🐼🐼", 0, 200), characterName: "Commander")
        #expect(transcript.entries[0].text == "🐼🐼")
    }

    private func fragment(_ speaker: LiveTranscript.Speaker, _ text: String, _ start: Int, _ end: Int) -> LiveTranscript {
        LiveTranscript(speaker: speaker, delta: text, startMilliseconds: start, endMilliseconds: end)
    }
}
