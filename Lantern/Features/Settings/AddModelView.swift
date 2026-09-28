import SwiftUI

/// For experienced users: bring a model from Hugging Face. The name is checked
/// against Hugging Face and against this device before anything is added, and
/// the model then downloads and runs like the built-in ones.
struct AddModelView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checking = false
    @State private var found: ModelEntry?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                TextField("owner/name", text: $name, prompt: Text("mlx-community/gemma-3-1b-it-4bit"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(check)
                    .onChange(of: name) { found = nil; problem = nil }
                Button(action: check) {
                    if checking { ProgressView() } else { Text("Check this model") }
                }
                .disabled(checking || name.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Hugging Face model")
            } footer: {
                Text("Lantern runs models in Apple's MLX format, most of them published under mlx-community on huggingface.co. Checking reads the model's public description from Hugging Face, the same request a download starts with. Nothing about you is sent.")
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.danger)
                }
            }

            if let found {
                let verdict = CustomModelInspector.fits(found, on: app.device)
                Section {
                    HStack(spacing: Theme.Space.s) {
                        StatusLight(verdict: verdict)
                        Text(found.displayName).font(.body.weight(.semibold))
                        if found.seesPhotos { Chip(text: "sees photos", systemImage: "eye") }
                    }
                    LabeledContent("Download", value: found.approximateBytes.byteText)
                    LabeledContent("Parameters", value: String(format: "about %.1f billion", found.parameterBillions))
                    LabeledContent("Type", value: found.family)
                    LabeledContent("Memory per 1,000 words", value: (found.kvBytesPerToken * 1333).byteText)
                    switch verdict {
                    case .go: Text("Fits this \(Platform.device) comfortably.").font(.caption).foregroundStyle(Theme.muted)
                    case .caution(let why): Text(why).font(.caption).foregroundStyle(Theme.warn)
                    case .no(let why): Text(why).font(.caption).foregroundStyle(Theme.danger)
                    }
                    Button("Add to my models") { add(found) }
                        .disabled(!verdict.allowsDownload)
                } header: {
                    Text("What Lantern found")
                } footer: {
                    Text("The sizes are worked out from the model's own description, the same way the built-in models were sized. Replies from a model you add are its publisher's work, not reviewed by Lantern.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Add a model")
    }

    private func check() {
        let repo = name
        checking = true
        problem = nil
        found = nil
        Task {
            do {
                let entry = try await CustomModelInspector.inspect(repo)
                found = entry
            } catch {
                problem = error.localizedDescription
            }
            checking = false
        }
    }

    private func add(_ entry: ModelEntry) {
        do {
            try app.addCustomModel(entry)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
