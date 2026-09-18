import SwiftUI

/// Lantern's look: a light you carry. The interface is a calm, trusted blue on
/// cool neutral ground, the kind of colour people already associate with tools
/// they rely on; the only warm thing on screen is the flame in the mark. Every
/// colour is a named asset with a light and a dark appearance, so nothing here
/// branches on the colour scheme. Type is plain San Francisco, nothing rounded.
enum Theme {
    static let background = Color("LanternBackground")
    static let surface = Color("LanternSurface")
    static let surfaceRaised = Color("LanternSurfaceRaised")
    static let ink = Color("LanternInk")
    static let muted = Color("LanternMuted")
    static let accent = Color("LanternAccent")
    static let flame = Color("LanternFlame")
    static let glow = Color("LanternGlow")
    static let guide = Color("LanternGuide")
    static let danger = Color("LanternDanger")
    static let warn = Color("LanternWarn")

    enum Radius {
        static let bubble: CGFloat = 18
        static let card: CGFloat = 16
        static let chip: CGFloat = 999
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Headings: the system face, a little heavier. Clean, nothing decorative.
    static func heading(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, weight: .semibold)
    }

    /// Numbers that change while you watch them keep their width.
    static func readout(_ style: Font.TextStyle = .footnote) -> Font {
        .system(style, weight: .medium).monospacedDigit()
    }
}

/// A soft amber halo, used behind the wordmark and the empty-chat mark.
struct GlowBackdrop: View {
    var strength: Double = 1
    var radius: CGFloat = 140

    var body: some View {
        // Clipped to a circle whose edge is where the gradient reaches zero, so
        // the frame's corners can never show as a faint square.
        Circle()
            .fill(RadialGradient(
                colors: [Theme.glow.opacity(0.6 * strength), Theme.glow.opacity(0)],
                center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
    }
}

/// The lantern mark drawn in SwiftUI so it scales anywhere.
struct LanternMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            GlowBackdrop(strength: 0.9, radius: size * 1.3)
            Image(systemName: "flame.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Theme.flame)
                .shadow(color: Theme.flame.opacity(0.6), radius: size * 0.2)
            RoundedRectangle(cornerRadius: size * 0.16)
                .strokeBorder(Theme.ink.opacity(0.85), lineWidth: size * 0.06)
                .frame(width: size * 0.6, height: size * 0.8)
        }
        .frame(width: size, height: size)
    }
}

/// A rounded card on the surface colour.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A small status dot: the green light and its siblings.
struct StatusLight: View {
    let verdict: Verdict

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.7), radius: 4)
    }

    private var color: Color {
        switch verdict {
        case .go: .green
        case .caution: Theme.warn
        case .no: Theme.danger
        }
    }
}

/// A pill of text.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

extension Int64 {
    /// "0.70 GB", "695 MB".
    var byteText: String {
        let gb = Double(self) / Double(1 << 30)
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", Double(self) / Double(1 << 20))
    }
}
