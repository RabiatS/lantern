import CoreGraphics
import PhotosUI
import SwiftUI

/// Turn a picked library item into a CGImage.
enum PickedPhoto {
    static func cgImage(from item: PhotosPickerItem) async -> CGImage? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Honour the orientation baked into the file by drawing through ImageIO.
        let options = [kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

#if os(iOS)
/// The system camera, returning an upright CGImage.
struct CameraView: UIViewControllerRepresentable {
    let onImage: (CGImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            parent.onImage(image?.upright.cgImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImage(nil)
            parent.dismiss()
        }
    }
}

private extension UIImage {
    /// Re-render so the pixel data is upright rather than relying on the
    /// orientation flag, which CGImage consumers ignore.
    var upright: UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif

/// A thumbnail for a CGImage that works on both platforms.
struct CGImageView: View {
    let image: CGImage

    var body: some View {
        Image(image, scale: 1, label: Text("Photo"))
            .resizable()
            .scaledToFill()
    }
}
