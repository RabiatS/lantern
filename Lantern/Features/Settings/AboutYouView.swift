import SwiftUI

/// A few optional lines about the person, for replies to use. Everything here
/// stays on this device and can be changed or deleted at any time.
struct AboutYouView: View {
    @Environment(AppState.self) private var app
    @State private var newMemory = ""
    @State private var confirmErase = false

    var body: some View {
        @Bindable var profile = app.profile
        Form {
            Section {
                Toggle("Use in replies", isOn: $profile.enabled)
                    .disabled(profile.isEmpty)
            } footer: {
                Text(profile.isEmpty
                     ? "Off until you write something below. Nothing here is needed; Lantern works the same without it."
                     : "Added to every reply's instructions, about \(profile.approximateWords) words. Switch off to pause it without deleting anything.")
            }

            Section("You") {
                TextField("Name", text: $profile.name, prompt: Text("What to call you"))
                TextField("Age", text: $profile.age, prompt: Text("Optional"))
                TextField("About you", text: $profile.about, prompt: Text("e.g. nurse, lives near the coast, vegetarian"), axis: .vertical)
                    .lineLimit(1 ... 3)
                TextField("How you like answers", text: $profile.style, prompt: Text("e.g. short, plain words, metric units"), axis: .vertical)
                    .lineLimit(1 ... 3)
            }

            Section {
                ForEach(profile.memories, id: \.self) { line in
                    Text(line)
                        .contextMenu {
                            Button("Forget", systemImage: "trash", role: .destructive) { profile.forget(line) }
                        }
                }
                .onDelete { profile.forget(at: $0) }
                HStack {
                    TextField("Add something to remember", text: $newMemory)
                        .onSubmit(addMemory)
                    Button("Add", action: addMemory)
                        .disabled(newMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || profile.memories.count >= Profile.maxMemories)
                }
            } header: {
                Text("Remember")
            } footer: {
                Text("Up to \(Profile.maxMemories) short notes. You can also choose \"Remember this\" on any message.")
            }

            Section {
                Button("Delete everything here", role: .destructive) { confirmErase = true }
                    .disabled(profile.isEmpty)
            } footer: {
                Text("Kept only on this \(Platform.device), never sent anywhere and left out of backups.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("About you")
        .confirmationDialog("Delete everything in About you?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                app.profile.eraseAll()
                app.profileChanged()
            }
        }
        .onDisappear { app.profileChanged() }
    }

    private func addMemory() {
        app.profile.remember(newMemory)
        newMemory = ""
        app.profileChanged()
    }
}
