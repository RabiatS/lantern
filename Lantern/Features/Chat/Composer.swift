import PhotosUI
import SwiftUI

/// The input row: a picture button, the text, send or stop.
struct Composer: View {
    @Environment(AppState.self) private var app
    @Binding var draft: String
    var composing: FocusState<Bool>.Binding
    @State private var pickedItem: PhotosPickerItem?
    @State private var showCamera = false

    private var canSend: Bool {
        !app.isBusy && (app.pendingImage != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let picture = app.pendingImage {
                attachment(picture)
            }
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                pictureMenu
                TextField(app.pendingImage == nil ? "Ask anything. No signal needed." : "Ask about the picture", text: $draft, axis: .vertical)
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
        }
        .onChange(of: pickedItem) {
            guard let item = pickedItem else { return }
            Task {
                let image = await PickedPhoto.cgImage(from: item)
                await MainActor.run {
                    app.pendingImage = image
                    pickedItem = nil
                }
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                if let image { app.pendingImage = image }
            }
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { composing.wrappedValue = false }
            }
        }
        #endif
    }

    /// Camera or library. Greyed out with a reason when no model on the phone can see.
    private var pictureMenu: some View {
        Menu {
            #if os(iOS)
            if CameraView.isAvailable {
                Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera") }
            }
            #endif
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
            }
            if app.pictures.isInstalled {
                Button {
                    app.makePicture(draft)
                    draft = ""
                } label: {
                    Label("Draw a picture from this text", systemImage: "paintbrush")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.isBusy)
            } else {
                Text("Download the picture maker in Settings to draw from text.")
            }
            if !app.canLook {
                Text(app.usingApple ? "Apple's model does not take pictures here. Switch to a Lantern model that sees photos." : "Download a model that sees photos in Settings.")
            }
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 22))
                .foregroundStyle((app.canLook || app.pictures.isInstalled) ? Theme.accent : Theme.muted.opacity(0.6))
                .frame(width: 34, height: 34)
        }
        .accessibilityLabel("Add a picture")
    }

    private func attachment(_ picture: CGImage) -> some View {
        HStack(spacing: Theme.Space.s) {
            CGImageView(image: picture)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Picture attached").font(.footnote.weight(.medium)).foregroundStyle(Theme.ink)
                Text(app.visionEntry.map { "\($0.displayName) will look at it" } ?? "No model on this phone can see yet")
                    .font(.caption).foregroundStyle(app.canLook ? Theme.muted : Theme.warn)
            }
            Spacer()
            Button { app.pendingImage = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
            }
            .accessibilityLabel("Remove picture")
        }
        .padding(Theme.Space.s)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func send() {
        app.send(draft)
        draft = ""
    }
}
