import SwiftUI

/// The input row. Camera and dictation will sit on the left once those land.
struct Composer: View {
    @Environment(AppState.self) private var app
    @Binding var draft: String
    var composing: FocusState<Bool>.Binding

    private var canSend: Bool {
        !app.isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Ask anything. No signal needed.", text: $draft, axis: .vertical)
                .lineLimit(1 ... 6)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .focused(composing)
                .submitLabel(.send)
                .onSubmit { if canSend { send() } }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            if app.isGenerating {
                Button { app.stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Stop")
            } else {
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend ? Theme.accent : Theme.muted.opacity(0.5))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { composing.wrappedValue = false }
            }
        }
        #endif
    }

    private func send() {
        app.send(draft)
        draft = ""
    }
}
