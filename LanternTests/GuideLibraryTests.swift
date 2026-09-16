import Foundation
import Testing
@testable import Lantern

struct GuideLibraryTests {
    let sample = """
    # Sample

    Intro text that is not part of any passage.

    ## Severe bleeding
    Press hard on the wound. Do not lift the cloth to look.

    ## Burns and scalds
    Cool under running water for twenty minutes.

    ## Empty section

    ## Flat tyre
    Loosen the wheel nuts before jacking.
    """

    @Test func chunksAtSecondLevelHeadingsAndDropsEmptyOnes() {
        let passages = GuideLibrary.chunk(sample, guide: .firstAid)
        #expect(passages.map(\.title) == ["Severe bleeding", "Burns and scalds", "Flat tyre"])
        #expect(passages[0].text == "Press hard on the wound. Do not lift the cloth to look.")
        #expect(passages[0].id == "first-aid/Severe bleeding")
    }

    @Test func stemmingAndStopwords() {
        #expect(GuideLibrary.terms(in: "The tyres are bleeding badly") == ["tyre", "bleed", "badly"])
        #expect(GuideLibrary.stem("batteries") == "battery")
        #expect(GuideLibrary.stem("press") == "press")
    }

    @Test func retrievalFindsTheRightPassageByWords() {
        let library = GuideLibrary(passages: GuideLibrary.chunk(sample, guide: .firstAid))
        let hits = library.retrieve("a deep cut that will not stop bleeding", in: .firstAid)
        #expect(hits.first?.passage.title == "Severe bleeding")
        let tyre = library.retrieve("my tyre is flat, how do I change the wheel", in: .firstAid)
        #expect(tyre.first?.passage.title == "Flat tyre")
    }

    @Test func nothingRelevantReturnsNothing() {
        let library = GuideLibrary(passages: GuideLibrary.chunk(sample, guide: .firstAid))
        let hits = library.retrieve("recommend a good novel", in: .firstAid)
        #expect(hits.allSatisfy { $0.score < 0.5 })
        #expect(library.retrieve("anything", in: .roadside).isEmpty)
    }

    @Test func bundledGuidesLoadAndAnswerTheSuggestedPrompts() {
        let library = GuideLibrary(bundle: .main)
        #expect(library.passages(in: .firstAid).count >= 15)
        #expect(library.passages(in: .roadside).count >= 10)
        #expect(library.passages(in: .outdoors).count >= 10)

        let bleeding = library.retrieve(Persona.firstAid.suggestedPrompt, in: .firstAid)
        #expect(bleeding.first?.passage.title == "Severe bleeding")
        let car = library.retrieve(Persona.roadside.suggestedPrompt, in: .roadside)
        #expect(car.contains { $0.passage.title.hasPrefix("Car will not start") })
        let lost = library.retrieve(Persona.outdoors.suggestedPrompt, in: .outdoors)
        #expect(lost.contains { $0.passage.title == "Lost: stop" || $0.passage.title == "Shelter and warmth first" })
    }

    @Test func groundedPromptWrapsPassagesAndQuestion() {
        let passage = Passage(guide: .firstAid, title: "Burns and scalds", text: "Cool under running water.")
        let prompt = GuideLibrary.groundedPrompt(question: "I burnt my hand", passages: [RetrievedPassage(passage: passage, score: 1)])
        #expect(prompt.contains("[Guide: Burns and scalds]"))
        #expect(prompt.hasSuffix("Question: I burnt my hand"))
        #expect(GuideLibrary.groundedPrompt(question: "hi", passages: []) == "hi")
    }
}
