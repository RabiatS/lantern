import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures attached to messages, as JPEG files next to the conversations.
/// Downscaled on the way in: the model never sees more than about a thousand
/// pixels on the long side, and neither does the phone's storage.
nonisolated struct ImageStore: Sendable {
    let directory: URL
    static let longestSide: CGFloat = 1024

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Images", directoryHint: .isDirectory)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        BackupExclusion.apply(to: directory)
    }

    func url(for name: String) -> URL {
        directory.appending(path: name)
    }

    /// Save a picture and return its file name.
    func save(_ image: CGImage) throws -> String {
        let name = UUID().uuidString + ".jpg"
        let scaled = Self.downscale(image, longestSide: Self.longestSide)
        let target = url(for: name)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return name
    }

    func load(_ name: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(for: name) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Remove pictures no surviving conversation refers to.
    func purge(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func downscale(_ image: CGImage, longestSide: CGFloat) -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = min(1, longestSide / max(width, height))
        guard scale < 1 else { return image }
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}
