import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct LanternApp: App {
    @State private var app = AppState()

    init() {
        #if os(macOS) && DEBUG
        WindowSnapshot.reportLater()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            root
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 640)
                .onAppear { WindowSnapshot.scheduleIfRequested() }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 640, height: 860)
        #endif
    }

    private var root: some View {
        RootView().environment(app)
    }
}

#if os(macOS) && DEBUG
/// `--snapshot=<path.png>` writes a picture of the first window a few seconds
/// after launch and quits, so the Mac layout can be checked from a script
/// without the screen-recording permission that screencapture needs. It
/// renders the Core Animation layer tree, which leaves Metal-backed SwiftUI
/// content blank, so it proves the window and the chrome, not the transcript.
/// The window report on stderr is what found the two launch problems on
/// macOS: Xcode 27's debug dylib, and bare command-line words, which AppKit
/// treats as documents to open.
enum WindowSnapshot {
    /// Print what AppKit knows about our windows, three seconds in.
    static func reportLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let windows = NSApp.windows
            FileHandle.standardError.write("lantern windows: \(windows.count) activation=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive)\n".data(using: .utf8)!)
            for w in windows {
                FileHandle.standardError.write("  \(type(of: w)) visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)\n".data(using: .utf8)!)
            }
            if LaunchArguments.value(for: "snapshot") != nil { scheduleIfRequested() }
        }
    }

    static func scheduleIfRequested() {
        guard let path = LaunchArguments.value(for: "snapshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            func log(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }
            guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else {
                log("snapshot: no window"); NSApp.terminate(nil); return
            }
            guard let view = window.contentView else { log("snapshot: no content view"); NSApp.terminate(nil); return }
            // SwiftUI draws into Core Animation layers; render the layer tree,
            // which a plain view cache leaves blank.
            let scale = window.backingScaleFactor
            let size = view.bounds.size
            guard let layer = view.layer,
                  let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                log("snapshot: no layer or context"); NSApp.terminate(nil); return
            }
            // Core Graphics is bottom-up; flip so the PNG reads top-down.
            context.translateBy(x: 0, y: size.height * scale)
            context.scaleBy(x: scale, y: -scale)
            layer.render(in: context)
            guard let image = context.makeImage() else { log("snapshot: no image"); NSApp.terminate(nil); return }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { log("snapshot: no png"); NSApp.terminate(nil); return }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                log("snapshot: wrote \(png.count) bytes to \(path)")
            } catch {
                log("snapshot: write failed \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}
#elseif os(macOS)
enum WindowSnapshot { static func scheduleIfRequested() {} }
#endif
