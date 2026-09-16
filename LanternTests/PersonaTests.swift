import Foundation
import Testing
@testable import Lantern

struct PersonaTests {
    @Test func everyPersonaIsCompleteAndDistinct() {
        let titles = Persona.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        for persona in Persona.allCases {
            #expect(!persona.instructions.isEmpty, "\(persona.title)")
            #expect(!persona.summary.isEmpty, "\(persona.title)")
            #expect(!persona.suggestedPrompt.isEmpty, "\(persona.title)")
        }
    }

    @Test func promptsStayShortEnoughForASmallModel() {
        // Every word of instruction is prefilled on each turn and a 1B model
        // follows a short brief better than a long one.
        for persona in Persona.allCases {
            let words = persona.instructions.split(separator: " ").count
            #expect(words <= 110, "\(persona.title) is \(words) words")
        }
    }

    @Test func safetyPersonasPointAtEmergencyServices() {
        for persona in [Persona.roadside, .firstAid, .calm] {
            #expect(persona.instructions.lowercased().contains("emergency services"), "\(persona.title)")
        }
    }

    @Test func rawValuesAreStableForUserDefaults() {
        #expect(Persona(rawValue: "general") == .general)
        #expect(Persona(rawValue: "electronicsTutor") == .electronicsTutor)
        #expect(Persona(rawValue: "firstAid") == .firstAid)
        #expect(Persona.allCases.first == .general)
    }
}
