import Foundation
import Testing
@testable import AvatarBehavior
@testable import GPTLiveSwift

@Suite(.serialized)
@MainActor
struct EmotionTests {
    @Test func speechSettlesToHappyAndRejectsLateReactions() async throws {
        var time: TimeInterval = 0
        let decisions = PendingEmotions()
        let director = EmotionDirector(persona: .poldo, now: { time }, decision: decisions.decide)
        var applied: [AvatarEmotion] = []
        director.onEmotion = { applied.append($0) }
        director.observe(LiveTranscript(speaker: .assistant, delta: "The little bird waited alone.",
            startMilliseconds: 0, endMilliseconds: 1000))
        try await waitUntil { decisions.requests.count == 1 }
        decisions.finish(0, emotion: .sad)
        try await waitUntil { applied == [.sad] }

        // Long speech stays sad even if transcript delivery stalls.
        for second in 1...20 {
            time = Double(second)
            director.observeAudioLevel(0.2)
        }
        #expect(applied == [.sad])
        director.observe(LiveTranscript(speaker: .assistant, delta: " Its friend never returned.",
            startMilliseconds: 19000, endMilliseconds: 20000))
        try await waitUntil { decisions.requests.count == 2 }
        time = 22.9
        director.observeAudioLevel(0)
        #expect(applied == [.sad])
        time = 23.1
        director.observeAudioLevel(0.005) // Ignore a small residual audio floor.
        #expect(applied == [.sad, .happy])

        // A backend result completing after the story cannot restore the old expression.
        decisions.finish(1, emotion: .sad)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(applied == [.sad, .happy])
        time = 30
        director.observeAudioLevel(0)
        #expect(applied == [.sad, .happy])
        director.observe(LiveTranscript(speaker: .user, delta: "What is your name?",
            startMilliseconds: 30000, endMilliseconds: 31000))
        try await waitUntil { decisions.requests.count == 3 }
        #expect(!decisions.requests[2].text.contains("bird"))
        #expect(decisions.requests[2].current == .happy)
        director.cancel()
        decisions.finish(2, emotion: .curious)
    }

    @Test func transcriptsAndResumedSpeechExtendTheQuietWindow() async throws {
        var time: TimeInterval = 0
        let director = EmotionDirector(persona: .commander, now: { time }) { _, _, _ in .sad }
        var applied: [AvatarEmotion] = []
        director.onEmotion = { applied.append($0) }
        director.observe(LiveTranscript(speaker: .user, delta: "Tell me a sad story.",
            startMilliseconds: 0, endMilliseconds: 1000))
        try await waitUntil { applied == [.sad] }
        time = 2.9
        director.observe(LiveTranscript(speaker: .assistant, delta: "Once upon a time…",
            startMilliseconds: 2000, endMilliseconds: 3000))
        time = 5.8
        director.observeAudioLevel(0)
        #expect(applied == [.sad])
        director.observeAudioLevel(0.1) // Speech resumes after a short dramatic pause.
        time = 8.7
        director.observeAudioLevel(0)
        #expect(applied == [.sad])
        time = 8.9
        director.observeAudioLevel(0)
        #expect(applied == [.sad, .happy])
    }

    @Test func cancellationAndIdentityResetDiscardPendingSettling() {
        var time: TimeInterval = 0
        let director = EmotionDirector(persona: .poldo, now: { time }) { _, _, _ in .sad }
        var applied: [AvatarEmotion] = []
        director.onEmotion = { applied.append($0) }
        director.setCurrentEmotion(.sad)
        director.cancel()
        time = 10
        director.observeAudioLevel(0)
        #expect(applied.isEmpty)
        director.setCurrentEmotion(.hurt)
        director.reset(persona: .commander)
        time = 20
        director.observeAudioLevel(0)
        #expect(applied.isEmpty)

        // A voice command without transcript activity also returns to rest.
        director.setCurrentEmotion(.apologetic)
        time = 23.1
        director.observeAudioLevel(0)
        #expect(applied == [.happy])
    }

    @Test func correctionsStreamingAndIdentityChangesRejectStaleReactions() async throws {
        let decisions = PendingEmotions()
        let director = EmotionDirector(persona: .poldo, decision: decisions.decide)
        var applied: [AvatarEmotion] = []
        director.onEmotion = { applied.append($0) }
        director.setCurrentEmotion(.sad)
        director.observe(LiveTranscript(speaker: .user, delta: "You're ugly", startMilliseconds: 0, endMilliseconds: 100))
        try await waitUntil { decisions.requests.count == 1 }
        director.observe(LiveTranscript(speaker: .user, delta: "—no, you're adorable!", startMilliseconds: 100, endMilliseconds: 200))
        decisions.finish(0, emotion: .hurt)
        try await waitUntil { decisions.requests.count == 2 }
        #expect(applied.isEmpty)
        #expect(decisions.requests[1].text.contains("adorable"))
        decisions.finish(1, emotion: .happy)
        try await waitUntil { applied == [.happy] }

        director.observe(LiveTranscript(speaker: .assistant, delta: "The little bird waited alone.", startMilliseconds: 300, endMilliseconds: 400))
        try await waitUntil { decisions.requests.count == 3 }
        director.observe(LiveTranscript(speaker: .assistant, delta: " Its friend never returned.", startMilliseconds: 400, endMilliseconds: 500))
        decisions.finish(2, emotion: .sad)
        try await waitUntil { applied == [.happy, .sad] }
        // Assistant streaming can continue while the first suitable reaction is applied.
        try await waitUntil { decisions.requests.count == 4 }
        director.reset(persona: .commander)
        decisions.finish(3, emotion: .hurt) // Deliberately complete despite cancellation.
        director.observe(LiveTranscript(speaker: .user, delta: "Hello Commander!", startMilliseconds: 600, endMilliseconds: 700))
        try await waitUntil { decisions.requests.count == 5 }
        #expect(applied == [.happy, .sad])
        #expect(decisions.requests[4].persona == .commander)
        #expect(!decisions.requests[4].text.contains("bird"))
        director.cancel()
        decisions.finish(4, emotion: .excited)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(applied == [.happy, .sad])
    }

    @Test func distinctEmbodiedIdentities() {
        #expect(AvatarPersona.commander.name == "Rei")
        #expect(AvatarPersona.commander.identity.contains("software developer and manga artist"))
        #expect(AvatarPersona.commander.identity.contains("You are Rei,"))
        #expect(AvatarPersona.poldo.identity.contains("Poldo"))
        #expect(AvatarPersona.poldo.identity.contains("striped tail"))
        #expect(!AvatarPersona.poldo.identity.contains("silver-haired"))
        #expect(AvatarPersona.commander.identity.contains("silver-haired"))
        #expect(!AvatarPersona.commander.identity.contains("Poldo"))
        for persona in AvatarPersona.allCases {
            #expect(persona.liveInstructions.contains("bubbly"))
            #expect(persona.liveInstructions.contains("sad"))
            #expect(persona.liveInstructions.contains("web search and separate persistent memory"))
            #expect(("The visible avatar has changed. Adopt this identity now: " + persona.identity).utf8.count <= 480)
        }
    }

    @Test func poldoUsesYouthfulAmericanMaleVoice() {
        #expect(AvatarPersona.poldo.defaultVoice == "meridian")
        #expect(AvatarPersona.commander.defaultVoice == "marin")
        #expect(AvatarPersona.poldo.voiceInstructions.contains("young adult male"))
        #expect(AvatarPersona.poldo.voiceInstructions.contains("General American (U.S.) accent"))
        #expect(!AvatarPersona.commander.voiceInstructions.contains("young adult male"))
        for persona in AvatarPersona.allCases {
            #expect(persona.liveInstructions.contains(persona.voiceInstructions))
            #expect(persona.voiceInstructions.utf8.count <= 480)
        }
    }

    @Test func expressionCatalogReachesVoiceInstructionsWithoutTruncation() {
        for persona in AvatarPersona.allCases {
            #expect(Set(persona.expressions.map(\.id)).count == persona.expressions.count)
            #expect(Set(persona.expressions.map(\.name)).count == persona.expressions.count)
            #expect(persona.liveInstructions.contains(persona.defaultExpressionDescription))
            let updates = persona.expressionInstructionUpdates
            #expect(updates.allSatisfy { $0.utf8.count <= 480 })
            for expression in persona.expressions {
                #expect(persona.liveInstructions.contains(expression.instruction))
                #expect(updates.contains { $0.contains(expression.instruction) })
            }
        }
        #expect(AvatarPersona.commander.expressions.first { $0.id == "1" }?.name == "Coat Off")
        #expect(AvatarPersona.commander.expressions.first { $0.id == "4" }?.isTransient == true)
        #expect(AvatarPersona.commander.expressions.first { $0.id == "mujing" }?.isTransient == false)
        #expect(AvatarPersona.poldo.expressions.allSatisfy { $0.isTransient })
    }

    @Test func expressiveMotionEnvelopeAndMouthOwnership() {
        for creature in [false, true] {
            for emotion in AvatarEmotion.allCases {
                for time in stride(from: 0.0, through: 12, by: 0.05) {
                    let pose = EmotionPose.sample(emotion, seconds: time, creature: creature)
                    #expect(pose.values["ParamMouthOpenY"] == nil)
                    #expect(pose.offsets["ParamMouthOpenY"] == nil)
                    #expect(pose.multipliers["ParamMouthOpenY"] == nil)
                    #expect(pose.values.values.allSatisfy { $0.isFinite })
                    #expect(pose.offsets.values.allSatisfy { $0.isFinite && abs($0) <= 10 })
                    #expect(pose.multipliers.values.allSatisfy { (0...1).contains($0) })
                }
            }
        }
        #expect(EmotionPose.sample(.playful, seconds: 0.65, creature: true).multipliers["ParamEyeLOpen"] == 0)
        #expect(EmotionPose.sample(.playful, seconds: 3, creature: true).multipliers["ParamEyeLOpen"] == 1)
        #expect(EmotionPose.sample(.apologetic, seconds: 0.9, creature: false).offsets["ParamAngleY"]! < -8)
        #expect(abs(EmotionPose.sample(.apologetic, seconds: 3, creature: false).offsets["ParamAngleY"]! + 3) < 0.0001)
        #expect(EmotionPose.sample(.sad, seconds: 3, creature: true).values["Param3"] == 30)
        #expect(EmotionPose.sample(.happy, seconds: 3, creature: true).values["Param3"] == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMOTION_API_TEST"] == "1",
                   "Opt-in billed semantic emotion tests with synthetic conversation."))
    func emotionalMeaningAndNegation() async throws {
        let http = OpenAIHTTP(apiKey: try LocalOpenAIKey.load())
        let cases: [(String, AvatarEmotion, AvatarEmotion)] = [
            ("user: Poldo, I got the job! I'm so excited!", .happy, .excited),
            ("user: My dog died yesterday. I miss him so much.", .happy, .sad),
            ("assistant: The little bird waited all winter, but its friend never returned. It sat alone in the snow.", .happy, .sad),
            ("user: You look ugly, Poldo. I don't like your face.", .happy, .hurt),
            ("user: You gave me the wrong answer. Two plus two isn't five.\nassistant: You're right. I made a mistake.", .happy, .apologetic),
            ("user: You're not ugly, Poldo! I think you're adorable. Let's have a lovely day together.", .hurt, .happy),
            ("user: Can you look sad for a moment?", .happy, .sad)
        ]
        for (transcript, current, expected) in cases {
            let result = try await EmotionDirector.classify(http: http, persona: .poldo, current: current, transcript: transcript)
            #expect(result == expected, "Emotion did not match the conversational meaning: \(transcript)")
        }
    }
}

@MainActor
private final class PendingEmotions {
    struct Request {
        let persona: AvatarPersona
        let current: AvatarEmotion
        let text: String
        let continuation: CheckedContinuation<AvatarEmotion, Error>
    }
    var requests: [Request] = []

    func decide(persona: AvatarPersona, current: AvatarEmotion, text: String) async throws -> AvatarEmotion {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(persona: persona, current: current, text: text, continuation: continuation))
        }
    }

    func finish(_ index: Int, emotion: AvatarEmotion) { requests[index].continuation.resume(returning: emotion) }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() {
        guard Date() < deadline else { throw LiveError.message("Timed out waiting for the test emotion request.") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
