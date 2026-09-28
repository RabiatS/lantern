import Foundation

nonisolated enum BackupExclusion {
    /// Keep a folder, and everything in it, out of iCloud and computer
    /// backups. Chats, pictures and the About you notes stay on this device
    /// only, which is what the "How Lantern works" page promises.
    static func apply(to directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
