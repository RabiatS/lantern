import SwiftUI

/// Pick what the assistant is for.
struct PersonaSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.s) {
                    ForEach(Persona.allCases, id: \.self) { persona in
                        PersonaRow(persona: persona, selected: persona == app.persona) {
                            app.persona = persona
                            dismiss()
                        }
                    }
                }
                .padding(Theme.Space.l)
            }
            .background(Theme.background)
            .navigationTitle("Persona")

            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }
}

private struct PersonaRow: View {
    let persona: Persona
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: persona.symbol)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .background(selected ? Theme.accent : Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(persona.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        if persona.guide != nil {
                            Chip(text: "guided", systemImage: "book.closed", tint: Theme.guide)
                        }
                    }
                    Text(persona.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
            .padding(Theme.Space.l)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
