import SwiftUI

/// The main screen: one conversation, the persona it is running under, and the
/// instrument strip while a reply is being written.
///
/// Laid out as a plain vertical stack, transcript over composer, so the
/// keyboard pushes the composer up with it. An inset composer looked the same
/// but let the keyboard cover the text being typed on a real phone.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var showHistory = false
    @State private var showPersonas = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                bottomBar
            }
            .background(Theme.background.ignoresSafeArea())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("History")
                }
                ToolbarItem(placement: .principal) {
                    Button { showPersonas = true } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Image(systemName: app.persona.symbol)
                            Text(app.persona.title)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(Theme.heading(.headline))
                        .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Change persona")
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: Theme.Space.s) {
                        Button { app.newConversation() } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New chat")
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Models and settings")
                    }
                }
            }
            .tint(Theme.accent)
        }
        .sheet(isPresented: $showHistory) { HistorySheet() }
        .sheet(isPresented: $showPersonas) { PersonaSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Space.m) {
                    if app.current.messages.isEmpty {
                        EmptyChat(persona: app.persona, fact: app.fact) { prompt in
                            app.send(prompt)
                        }
                        .padding(.top, Theme.Space.xl)
                    }
                    ForEach(app.current.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if app.isCompacting {
                        HStack(spacing: Theme.Space.s) {
                            ProgressView().tint(Theme.accent)
                            Text("Summarising older messages so the chat can go on…")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.s)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onChange(of: app.current.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") }
            }
            .onChange(of: app.streamingText) {
                proxy.scrollTo("bottom")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.Space.s) {
            if let live = app.live {
                LiveStrip(live: live)
            }
            if let context = app.context, context.isHigh, !app.isCompacting {
                ContextChip(usage: context) { app.compact() }
            }
            if app.unloadedByPressure {
                Text("The model was set down to free memory. It picks back up on your next message.")
                    .font(.caption)
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = app.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Composer(draft: $draft, composing: $composing)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.background)
    }
}

/// What an empty chat shows: the persona, one tap to try it, and something
/// worth knowing about how this works. The card goes away with the first message.
private struct EmptyChat: View {
    let persona: Persona
    let fact: String
    let start: (String) -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            LanternMark(size: 64)
            VStack(spacing: Theme.Space.xs) {
                Text(persona.title)
                    .font(Theme.heading(.title2))
                    .foregroundStyle(Theme.ink)
                Text(persona.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            Button {
                start(persona.suggestedPrompt)
            } label: {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(Theme.accent)
                    Text(persona.suggestedPrompt)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Label("Did you know", systemImage: "lightbulb")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(fact)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.leading)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            Text("No signal needed. Nothing leaves this phone.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// The context window filling up, with the way out.
private struct ContextChip: View {
    let usage: ContextUsage
    let compact: () -> Void

    var body: some View {
        HStack {
            Text("Context \(Int(usage.fraction * 100))% full")
                .font(Theme.readout(.caption))
            Spacer()
            Button("Compact", action: compact)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(usage.isCritical ? Theme.warn : Theme.muted)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surfaceRaised, in: Capsule())
    }
}
