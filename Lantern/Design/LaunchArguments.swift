import Foundation

/// Debug launch arguments, `--key=value` only.
///
/// On macOS, AppKit treats any bare argument as a document to open, and a
/// SwiftUI app launched "with documents" never opens its plain window. So the
/// screenshot flags take the value with an equals sign, never as a second word.
enum LaunchArguments {
    static func value(for key: String) -> String? {
        #if DEBUG
        let prefix = "--\(key)="
        return CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        #else
        return nil
        #endif
    }

    static func has(_ flag: String) -> Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--\(flag)")
        #else
        return false
        #endif
    }
}
