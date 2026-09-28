#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The chat as a Mac window rather than a phone screen: chats in a sidebar,
/// the persona and settings in the toolbar, and the conversation in a column
/// narrow enough to read. The transcript and the composer are the same views
/// the phone uses.
struct MacChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var dropTargeted = false
    @State private var metrics = MacMetrics()

    var body: some View {
        NavigationSplitView {
            MacSidebar(metrics: metrics)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            VStack(spacing: 0) {
                ChatTranscript()
                ChatBottomBar(draft: $draft, composing: $composing)
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .overlay { if dropTargeted { dropHint } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let image = MacImageFile.cgImage(at: url) else { return false }
                app.pendingImage = image
                composing = true
                return true
            } isTargeted: { dropTargeted = $0 }
            .navigationTitle(app.persona.title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
        }
        .tint(Theme.accent)
        .onAppear {
            composing = true
            metrics.start()
        }
        .onDisappear { metrics.stop() }
        .onChange(of: app.current.id) { composing = true }
    }

    private var subtitle: String {
        app.usingApple ? "Apple Intelligence, on this Mac" : "\(app.selectedEntry.displayName), on this Mac"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            @Bindable var app = app
            // A menu rather than a bare picker: in a toolbar the picker showed
            // only the icon, so nobody could tell which persona was on.
            Menu {
                Picker("Persona", selection: $app.persona) {
                    ForEach(Persona.allCases, id: \.self) { persona in
                        Label(persona.title, systemImage: persona.symbol).tag(persona)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(app.persona.title, systemImage: app.persona.symbol)
                    .labelStyle(.titleAndIcon)
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .help("What the assistant is for")
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Models and settings", systemImage: "slider.horizontal.3")
            }
            .help("Models and settings")
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                Label(app.canLook ? "Drop a picture to ask about it" : "Drop a picture. A model that sees photos is needed to read it.",
                      systemImage: "photo")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
            }
            .padding(Theme.Space.l)
            .allowsHitTesting(false)
    }
}

/// New chat, then the last seven days of chats, newest first.
private struct MacSidebar: View {
    @Environment(AppState.self) private var app
    let metrics: MacMetrics
    @State private var confirmDeleteAll = false

    private var selection: Binding<UUID?> {
        Binding(
            get: { app.current.id },
            set: { id in
                guard let id, id != app.current.id,
                      let conversation = app.history.first(where: { $0.id == id }) else { return }
                app.open(conversation)
            })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(app.history) { conversation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .lineLimit(1)
                        Text(expiry(conversation))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Delete Chat", systemImage: "trash", role: .destructive) { app.delete(conversation) }
                    }
                }
            } header: {
                Text("Last \(ConversationStore.retentionDays) days")
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.history.isEmpty {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Chats stay for \(ConversationStore.retentionDays) days, then delete themselves."))
            }
        }
        .safeAreaInset(edge: .top) {
            Button { app.newConversation() } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if !app.history.isEmpty {
                    Button("Delete All Chats…", role: .destructive) { confirmDeleteAll = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Label("Nothing leaves this Mac", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().padding(.vertical, Theme.Space.xs)
                MacMetricsCorner(metrics: metrics)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
        }
        .confirmationDialog("Delete all chats?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { app.deleteAllConversations() }
        } message: {
            Text("This removes every chat from this Mac now, instead of waiting \(ConversationStore.retentionDays) days.")
        }
    }

    private func expiry(_ conversation: Conversation) -> String {
        let days = app.daysLeft(for: conversation)
        return days == 0 ? "Deletes today" : "Deletes in \(days) day\(days == 1 ? "" : "s")"
    }
}

/// Read a picture file dropped on the window or chosen from Finder.
enum MacImageFile {
    static func cgImage(at url: URL) -> CGImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
#endif
