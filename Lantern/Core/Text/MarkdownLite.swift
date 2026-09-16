import Foundation

/// The model writes Markdown. SwiftUI's `Text` renders the inline part of it
/// (bold, italic, code, links) but not block syntax, so headings would show
/// their hashes and bullets their dashes. This rewrites the block syntax into
/// something inline rendering can show, and leaves everything else alone.
nonisolated enum MarkdownLite {
    /// Block syntax to inline: `## Title` becomes `**Title**`, `- item` and
    /// `* item` become `• item`. Numbered lists already read fine. Fenced code
    /// keeps its fences so it stays visibly code.
    static func normalize(_ text: String) -> String {
        var output: [String] = []
        var inFence = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                output.append(line)
                continue
            }
            if inFence {
                output.append(line)
                continue
            }
            if let heading = heading(in: trimmed) {
                output.append("**\(heading)**")
                continue
            }
            if let bullet = bullet(in: line) {
                output.append(bullet)
                continue
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// `AttributedString` for display. Falls back to the plain text if the
    /// Markdown parser rejects something, which happens mid-stream when a `**`
    /// has not been closed yet.
    static func attributed(_ text: String) -> AttributedString {
        let normalized = normalize(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(text)
    }

    private static func heading(in line: String) -> String? {
        var hashes = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#" {
            hashes += 1
            index = line.index(after: index)
        }
        guard hashes > 0, hashes <= 6, index < line.endIndex, line[index] == " " else { return nil }
        let title = line[index...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    private static func bullet(in line: String) -> String? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(leading.count)
        guard rest.count >= 2 else { return nil }
        let marker = rest.first!
        guard marker == "-" || marker == "*", rest.dropFirst().first == " " else { return nil }
        // `**bold**` at the start of a line is emphasis, not a bullet.
        if marker == "*", rest.dropFirst().first == "*" { return nil }
        return leading + "• " + rest.dropFirst(2)
    }
}
