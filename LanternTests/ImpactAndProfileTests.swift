import Foundation
import Testing
@testable import Lantern

@MainActor
struct ImpactAndProfileTests {
    @Test func waterIsCountedPerReplyAtTheMeasuredFigure() {
        let impact = Impact()
        impact.seedPreview(replies: 1000, tokens: 0, seconds: 0, characters: 0)
        #expect(abs(impact.waterSavedMillilitres - 260) < 0.001)
        #expect(abs(impact.glassesOfWaterSaved - 1.04) < 0.001)
        #expect(SettingsView.water(260) == "260 mL")
        #expect(SettingsView.water(1500) == "1.50 L")
    }

    @Test func aboutYouIsOffUntilSomethingIsWrittenAndStaysSmall() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = Profile(directory: directory)
        #expect(profile.promptBlock == nil)

        profile.name = "Sam"
        let block = try #require(profile.promptBlock)
        #expect(block.contains("Their name: Sam."))

        for index in 0 ..< 20 { profile.remember(String(repeating: "note \(index) ", count: 30)) }
        #expect(profile.memories.count == Profile.maxMemories)
        #expect(profile.memories.allSatisfy { $0.count <= Profile.maxMemoryLength })
        #expect((profile.promptBlock ?? "").count <= Profile.maxPromptCharacters)

        profile.enabled = false
        #expect(profile.promptBlock == nil)

        let reopened = Profile(directory: directory)
        #expect(reopened.name == "Sam")
        #expect(reopened.enabled == false)

        reopened.eraseAll()
        #expect(Profile(directory: directory).isEmpty)
    }
}
