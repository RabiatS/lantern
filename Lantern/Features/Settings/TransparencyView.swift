import SwiftUI

/// How Lantern works, in plain words, using this phone's own numbers. The
/// promise of the app is that nothing is hidden, so nothing here is either.
struct TransparencyView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                intro
                section("Where the answers come from",
                        "A language model is a very large table of numbers that learned patterns of language from text. Lantern downloads one of these once, about the size of a few hundred photos, and keeps it on this phone. When you ask something, the phone's own chip runs the numbers. No message is sent anywhere. You can turn on airplane mode and nothing changes.")
                section("Why your phone can run this much",
                        memoryStory)
                section("What comes with iOS, and what Lantern adds", platformStory)
                section("Why some models are warned or missing",
                        "Every model needs its own weight in memory plus room to remember the conversation. Lantern adds those up before you download and shows a green, amber or red light. Green means comfortable. Amber means it will work but may be cut short when memory runs low. Red means it would be shut down by the phone, so it is not offered.")
                section("What the numbers under a reply mean",
                        "\"tok/s\" is tokens per second: how many word pieces the model writes each second. A token is roughly three quarters of a word. \"To first\" is how long you waited for the first one. These change with the length of the conversation and with how warm the phone is.")
                section("Why long chats get summarised",
                        "The model can only pay attention to a limited stretch of text at once, a few thousand tokens on this phone. When a chat gets close to that, Lantern asks the model to write a short summary of the older messages and continues from the summary. You keep the full conversation on screen; the model keeps the gist.")
                section("Where the safety personas get their facts",
                        "First aid, roadside and outdoors do not rely on the model's memory. Each question is matched against short passages of reviewed text that ship inside the app, and the model is told to answer only from those. The reply names the passages it used, so you can read the source yourself. If nothing matches, it says so and tells you to call for help.")
                section("What is stored and for how long",
                        "Chats are kept on this phone for \(ConversationStore.retentionDays) days after their last message, then deleted. Model files stay until you delete them. Benchmark and diagnostic files are written to the Files app, where you can read or delete them. Nothing is backed up to iCloud and nothing is sent to anyone.")
                section("Why it gets warm and uses battery",
                        "Writing a reply runs the graphics chip flat out for a few seconds. That is normal, and it is the same work a server would do, only here on a chip that draws a few watts instead of a few hundred. A long session will warm the phone, and the phone will slow the model down to stay cool. The readout shows when that happens.")
                section("How the savings in Settings are worked out",
                        "Replies and words are simply counted. The energy line is an estimate, so its assumptions are here: a reply from a data centre is taken as 0.3 watt-hours, the lower and more recent of published figures for a chat query, and this phone is taken as drawing 6 watts for the seconds it spent writing, which is typical for a phone chip under full load. The network between you and the data centre, and the servers kept running for you while idle, are not counted, so the real saving is larger. A phone charge is about 15 watt-hours.")
                section("What it is not good at",
                        "It knows nothing after its training, so it cannot tell you the weather or the news. It can be confidently wrong, and small models are wrong more often. Treat it as a fast, private writing and explaining partner, and check anything that matters.")
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.background)
        .navigationTitle("How Lantern works")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            LanternMark(size: 56)
            Text("Everything Lantern does happens on this phone. This page explains how, without the jargon.")
                .font(.body)
                .foregroundStyle(Theme.ink)
        }
    }

    private var memoryStory: String {
        let total = app.device.physicalMemory.byteText
        let available = app.device.availableMemory.byteText
        let tierLine: String
        switch app.device.tier {
        case .unsupported: tierLine = "That is not enough for any model in the catalog to run with room to spare."
        case .compact: tierLine = "That is enough for the smallest models here, the ones about a billion numbers in size."
        case .standard: tierLine = "That is comfortable for the smallest models here and tight for the 3 billion size."
        case .pro: tierLine = "That is comfortable for everything here up to 3 billion numbers, and tight for the largest."
        }
        return "This iPhone has \(total) of memory. iOS never lets one app take all of it, because the camera, your messages and the rest of the phone need to keep working. Right now Lantern is allowed about \(available). \(tierLine) The limit moves as other apps open and close, which is why Lantern checks it live rather than once."
    }

    private var platformStory: String {
        let gpu = app.device.gpuName.replacingOccurrences(of: " GPU", with: "")
        let apple: String
        switch app.appleStatus {
        case .available:
            apple = "This device also has Apple Intelligence, which includes a built-in model of about 3 billion parameters that iOS keeps loaded and shares between apps. Lantern can answer with it too, and uses it to write the summaries that keep long chats going. It is a strong general model, but its numbers are Apple's to manage: you cannot see its memory or choose its size."
        case .notEligible:
            apple = "Apple Intelligence is not on this device, so there is no built-in model to borrow. Everything here runs on the model Lantern downloads."
        case .notEnabled:
            apple = "Apple Intelligence is turned off on this device. Turned on, it adds a built-in model Lantern could answer with and use for summaries."
        case .notReady:
            apple = "Apple Intelligence is still preparing its model on this device. Once ready, Lantern can answer with it and use it for summaries."
        case .unsupportedOS:
            apple = "This version of the system has no built-in language model. Everything here runs on the model Lantern downloads."
        }
        let storage = app.device.freeDisk.byteText
        return "The chip is a \(gpu), with a graphics part in the \(app.device.gpuFamily) family. That part runs the model's arithmetic; the Neural Engine on the same chip is used by iOS for its own features. \(apple) What Lantern adds is a model you choose and can inspect: with \(storage) free, there is room for every model in the catalog; the largest weighs about 4.5 GB. More memory unlocks larger models, more storage lets you keep more of them, and a newer graphics family makes each one faster."
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title)
                .font(Theme.heading(.headline))
                .foregroundStyle(Theme.ink)
            Text(body)
                .font(.body)
                .foregroundStyle(Theme.muted)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
