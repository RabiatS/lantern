import SwiftUI

/// One message. The row for the reply being written reads the streaming text
/// from the app state, so it is the only row that redraws while tokens arrive.
struct MessageBubble: View {
    @Environment(AppState.self) private var app
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .system:
            systemLine
        case .user:
            HStack {
                Spacer(minLength: 48)
                bubble(text: message.text, isUser: true)
            }
        case .assistant:
            HStack(alignment: .bottom) {
                assistantBubble
                Spacer(minLength: 32)
            }
        }
    }

    private var isStreaming: Bool { app.streamingMessageId == message.id }

    private var assistantBubble: some View {
        let text = isStreaming ? (app.streamingText ?? "") : message.text
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if text.isEmpty {
                ThinkingDots()
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            } else {
                bubble(text: text, isUser: false)
            }
            if let sources = message.sources, !sources.isEmpty {
                Label(sources.joined(separator: " · "), systemImage: "book.closed")
                    .font(.caption2)
                    .foregroundStyle(Theme.guide)
                    .padding(.leading, Theme.Space.s)
            }
            if let stats = message.stats {
                Text(AppState.statsLine(stats))
                    .font(Theme.readout(.caption2))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, Theme.Space.s)
            }
        }
    }

    private func bubble(text: String, isUser: Bool) -> some View {
        Text(MarkdownLite.attributed(text))
            .font(.body)
            .foregroundStyle(isUser ? Color.white : Theme.ink)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            .background(
                isUser ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface),
                in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(text) }
            }
    }

    private var systemLine: some View {
        Text(message.text)
            .font(.caption)
            .foregroundStyle(Theme.muted)
            .italic()
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xs)
    }
}

/// Three dots that breathe while the first token is on its way.
private struct ThinkingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Theme.flame)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * abs(sin(phase + Double(index) * 0.9)))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
