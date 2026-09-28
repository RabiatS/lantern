import Foundation
import Observation

/// A few lines about the person, kept on this device and added to the model's
/// instructions so replies can use their name, their preferences and the
/// handful of things they asked Lantern to remember.
///
/// Small on purpose. Everything here is sent to the model with every reply,
/// so it is capped at about 200 tokens: enough for a name and a short list,
/// not enough to crowd out the conversation on a phone with a 2,048-token
/// window. It is off until something is written in it, and one switch pauses it.
@Observable
final class Profile {
    static let maxMemories = 12
    static let maxMemoryLength = 140
    static let maxFieldLength = 160
    /// Characters the whole block may take in the instructions, about 200 tokens.
    static let maxPromptCharacters = 800

    var name = "" { didSet { save() } }
    var age = "" { didSet { save() } }
    var about = "" { didSet { save() } }
    var style = "" { didSet { save() } }
    private(set) var memories: [String] = []
    var enabled = true { didSet { save() } }

    private let file: URL
    private var loading = false

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Profile", directoryHint: .isDirectory)) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BackupExclusion.apply(to: directory)
        file = directory.appending(path: "about-you.json")
        load()
    }

    var isEmpty: Bool {
        [name, age, about, style].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && memories.isEmpty
    }

    /// In use: something is written and the switch is on.
    var isActive: Bool { enabled && !isEmpty }

    func remember(_ text: String) {
        let line = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxMemoryLength))
        guard !line.isEmpty, !memories.contains(line) else { return }
        memories.append(line)
        if memories.count > Self.maxMemories { memories.removeFirst(memories.count - Self.maxMemories) }
        save()
    }

    func forget(at offsets: IndexSet) {
        memories.remove(atOffsets: offsets)
        save()
    }

    func forget(_ line: String) {
        memories.removeAll { $0 == line }
        save()
    }

    func eraseAll() {
        loading = true
        name = ""; age = ""; about = ""; style = ""
        memories = []
        enabled = true
        loading = false
        try? FileManager.default.removeItem(at: file)
    }

    /// What is added to the instructions, or nil when there is nothing to add.
    var promptBlock: String? {
        guard isActive else { return nil }
        func clean(_ text: String) -> String {
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxFieldLength))
        }
        var lines: [String] = []
        if !clean(name).isEmpty { lines.append("Their name: \(clean(name)).") }
        if !clean(age).isEmpty { lines.append("Their age: \(clean(age)).") }
        if !clean(about).isEmpty { lines.append("About them: \(clean(about))") }
        if !clean(style).isEmpty { lines.append("How they like answers: \(clean(style))") }
        if !memories.isEmpty {
            lines.append("Things they asked you to remember:")
            lines += memories.map { "- \($0)" }
        }
        var block = "About the person you are talking with, written by them. Use it only where it helps; do not repeat it back unless asked.\n"
            + lines.joined(separator: "\n")
        if block.count > Self.maxPromptCharacters { block = String(block.prefix(Self.maxPromptCharacters)) }
        return block
    }

    /// A plain-words size for the settings page.
    var approximateWords: Int { (promptBlock?.count ?? 0) / 5 }

    // MARK: File

    private struct Saved: Codable {
        var name, age, about, style: String
        var memories: [String]
        var enabled: Bool
    }

    private func load() {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        loading = true
        name = saved.name; age = saved.age; about = saved.about; style = saved.style
        memories = saved.memories
        enabled = saved.enabled
        loading = false
    }

    private func save() {
        guard !loading else { return }
        if isEmpty && enabled {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let saved = Saved(name: name, age: age, about: about, style: style, memories: memories, enabled: enabled)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }
}
