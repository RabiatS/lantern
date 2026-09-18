import Foundation
import Observation

/// What staying on the phone has saved. Counted honestly: replies, tokens and
/// seconds of generation are measured; energy is an estimate with its
/// assumptions written down, and shown as such.
@Observable
final class Impact {
    private(set) var replies = 0
    private(set) var tokens = 0
    private(set) var generationSeconds = 0.0
    private(set) var charactersKeptOnPhone = 0

    private static let key = "lantern.impact"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            replies = saved.replies
            tokens = saved.tokens
            generationSeconds = saved.generationSeconds
            charactersKeptOnPhone = saved.charactersKeptOnPhone
        }
    }

    private struct Saved: Codable {
        var replies: Int
        var tokens: Int
        var generationSeconds: Double
        var charactersKeptOnPhone: Int
    }

    func record(stats: GenerationStats, promptCharacters: Int) {
        replies += 1
        tokens += stats.generatedTokens
        generationSeconds += stats.promptSeconds + (stats.tokensPerSecond > 0 ? Double(stats.generatedTokens) / stats.tokensPerSecond : 0)
        charactersKeptOnPhone += promptCharacters
        let saved = Saved(replies: replies, tokens: tokens, generationSeconds: generationSeconds, charactersKeptOnPhone: charactersKeptOnPhone)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    // MARK: Estimates, with the assumptions in the open

    /// Energy a data-centre reply costs, in watt-hours. Published estimates for
    /// a chat query range from about 0.3 Wh (Epoch AI, 2025, for a typical
    /// GPT-4o query) to around 3 Wh (earlier figures). The lower, newer number
    /// is used so the saving is not overstated.
    static let cloudWattHoursPerReply = 0.3

    /// Power the phone draws while the model writes, in watts. A phone SoC
    /// under sustained GPU load sits around four to eight watts; six is used.
    static let phoneWattsWhileGenerating = 6.0

    /// Watt-hours the phone spent on all replies so far.
    var phoneWattHours: Double { Self.phoneWattsWhileGenerating * generationSeconds / 3600 }

    /// Watt-hours the same replies would have cost in a data centre, before
    /// counting the network and the idle capacity kept warm for them.
    var cloudWattHours: Double { Double(replies) * Self.cloudWattHoursPerReply }

    var wattHoursSaved: Double { max(0, cloudWattHours - phoneWattHours) }

    /// A phone battery holds roughly 15 Wh; this puts the saving in a unit
    /// people can picture.
    var phoneChargesSaved: Double { wattHoursSaved / 15 }

    /// One LED bulb at 10 W: hours it could have run on the energy saved.
    var ledBulbHours: Double { wattHoursSaved / 10 }
}
