import SwiftUI

/// The instrument. While a reply streams: rate, memory, thermal state, live.
/// Tap for the full readout.
struct LiveStrip: View {
    let live: LiveStats
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                PulseDot()
                Text(String(format: "%.0f tok/s", live.tokensPerSecond))
                Text(live.memory.mlxActive.byteText)
                Text(BenchmarkRunner.name(live.memory.thermalState))
                    .foregroundStyle(thermalColor)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            .font(Theme.readout(.footnote))
            .foregroundStyle(Theme.ink)
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.xs) {
                    row("Tokens", "\(live.tokens)")
                    row("Elapsed", String(format: "%.1f s", live.elapsed))
                    row("MLX active", live.memory.mlxActive.byteText)
                    row("MLX peak", live.memory.mlxPeak.byteText)
                    row("App may still use", live.memory.available.byteText)
                }
                .font(Theme.readout(.caption))
                .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(value).foregroundStyle(Theme.ink)
        }
    }

    private var thermalColor: Color {
        switch live.memory.thermalState {
        case .nominal: Theme.muted
        case .fair: Theme.warn
        case .serious, .critical: Theme.danger
        @unknown default: Theme.muted
        }
    }
}

/// A small amber dot that breathes while generation runs.
private struct PulseDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.flame)
            .frame(width: 8, height: 8)
            .shadow(color: Theme.flame.opacity(on ? 0.9 : 0.2), radius: on ? 6 : 2)
            .opacity(on ? 1 : 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
