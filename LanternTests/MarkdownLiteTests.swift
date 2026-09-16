import Foundation
import Testing
@testable import Lantern

struct MarkdownLiteTests {
    @Test func headingsBecomeBold() {
        #expect(MarkdownLite.normalize("## Ohm's law") == "**Ohm's law**")
        #expect(MarkdownLite.normalize("#not a heading") == "#not a heading")
        #expect(MarkdownLite.normalize("####### too many") == "####### too many")
    }

    @Test func dashAndStarBulletsBecomeDots() {
        #expect(MarkdownLite.normalize("- one\n* two\n  - nested") == "• one\n• two\n  • nested")
        #expect(MarkdownLite.normalize("**bold** start") == "**bold** start")
        #expect(MarkdownLite.normalize("1. first\n2. second") == "1. first\n2. second")
    }

    @Test func fencedCodeIsLeftAlone() {
        let code = "```swift\n# comment\n- not a bullet\n```"
        #expect(MarkdownLite.normalize(code) == code)
    }

    @Test func attributedRendersBoldAndSurvivesUnclosedMarkup() {
        let done = MarkdownLite.attributed("Use **Ohm's law**: V = IR")
        #expect(String(done.characters) == "Use Ohm's law: V = IR")
        let midStream = MarkdownLite.attributed("Use **Ohm")
        #expect(!String(midStream.characters).isEmpty)
    }
}
