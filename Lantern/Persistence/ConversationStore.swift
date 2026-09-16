import Foundation

/// One JSON file per conversation in Application Support. Plain files, so the
/// whole history is readable, exportable and deletable without a database.
///
/// History is kept for seven days from the last message and then deleted. A
/// chat about a flat tyre on a Tuesday does not need to exist in October, and
/// nothing about the app should accumulate on the phone.
nonisolated struct ConversationStore: Sendable {
    static let retentionDays = 7

    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Conversations", directoryHint: .isDirectory)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func loadAll() -> [Conversation] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Conversation.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversation: Conversation) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(conversation)
        try data.write(to: url(for: conversation.id), options: .atomic)
    }

    func delete(_ id: UUID) throws {
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// When a conversation will be deleted: seven days after its last message.
    static func expiry(of conversation: Conversation) -> Date {
        conversation.updatedAt.addingTimeInterval(TimeInterval(retentionDays) * 86_400)
    }

    /// Delete every conversation past its expiry. Called at launch and whenever
    /// the app comes to the foreground. Returns how many went.
    @discardableResult
    func purgeExpired(now: Date = Date()) -> Int {
        var removed = 0
        for conversation in loadAll() where Self.expiry(of: conversation) <= now {
            if (try? delete(conversation.id)) != nil { removed += 1 }
        }
        return removed
    }

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
