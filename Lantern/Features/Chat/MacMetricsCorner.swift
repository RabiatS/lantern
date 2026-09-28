#if os(macOS)
import Charts
import SwiftUI

/// A small gauge in the sidebar's corner: a heat dot, a line for the graphics
/// chip, and two numbers. Hover for a sentence, click for the panel.
struct MacMetricsCorner: View {
    let metrics: MacMetrics
    @State private var showPanel = false

    var body: some View {
        Button { showPanel.toggle() } label: {
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(MacHeat.color(metrics.latest?.thermal))
                    .frame(width: 8, height: 8)
                Sparkline(values: metrics.samples.map { $0.gpuBusy ?? 0 })
                    .frame(width: 44, height: 14)
                Text(summary)
                    .font(Theme.readout(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hoverText)
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            MacMetricsPanel(metrics: metrics)
        }
        .accessibilityLabel("This Mac right now")
        .accessibilityValue(hoverText)
    }

    private var summary: String {
        guard let sample = metrics.latest else { return "Reading…" }
        let gpu = sample.gpuBusy.map { "GPU \(Int(($0 * 100).rounded()))%" } ?? "GPU –"
        return "\(gpu) · \(sample.appMemory.byteText)"
    }

    private var hoverText: String {
        guard let sample = metrics.latest else { return "Reading this Mac." }
        var parts = [MacHeat.sentence(sample.thermal)]
        if let gpu = sample.gpuBusy { parts.append("The graphics chip is \(Int((gpu * 100).rounded()))% busy.") }
        parts.append("Lantern is using \(sample.appMemory.byteText) of memory. Click for more.")
        return parts.joined(separator: " ")
    }
}

/// The panel: each reading with a minute of history and one plain sentence.
private struct MacMetricsPanel: View {
    let metrics: MacMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("This Mac, the last minute")
                .font(Theme.heading(.headline))
            if let sample = metrics.latest {
                heat(sample)
                chartRow(
                    title: "Graphics chip",
                    value: sample.gpuBusy.map(percent) ?? "Not reported",
                    values: metrics.samples.map { $0.gpuBusy ?? 0 },
                    explain: "Where the model does its arithmetic. It jumps while a reply is being written and settles after.")
                chartRow(
                    title: "Processor",
                    value: sample.cpuBusy.map(percent) ?? "Measuring",
                    values: metrics.samples.map { $0.cpuBusy ?? 0 },
                    explain: "Every app on this Mac together. Lantern's own share is \(sample.appCPU.map(percent) ?? "being measured"); the chip, not the processor, runs the model.")
                memory(sample)
                power(sample)
            } else {
                ProgressView()
            }
            Text("Read once a second while this window is open, from what macOS reports to apps. Nothing is stored or sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.l)
        .frame(width: 360)
    }

    private func heat(_ sample: MacSample) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("Heat").font(.subheadline.weight(.semibold))
                Spacer()
                Text(MacHeat.name(sample.thermal))
                    .font(Theme.readout(.subheadline))
                    .foregroundStyle(MacHeat.color(sample.thermal))
            }
            HStack(spacing: 3) {
                ForEach(0 ..< 4) { step in
                    Capsule()
                        .fill(step <= MacHeat.level(sample.thermal) ? MacHeat.color(sample.thermal) : Color.secondary.opacity(0.2))
                        .frame(height: 6)
                }
            }
            Text(MacHeat.sentence(sample.thermal) + " macOS does not give apps a temperature in degrees; it reports how hard it is working to stay cool, in four steps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func memory(_ sample: MacSample) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("Memory").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(sample.systemUsed.byteText) of \(sample.systemTotal.byteText)")
                    .font(Theme.readout(.subheadline))
            }
            GeometryReader { geometry in
                let total = max(1, Double(sample.systemTotal))
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Color.secondary.opacity(0.45))
                        .frame(width: width * min(1, Double(sample.systemUsed) / total))
                    Capsule().fill(Theme.accent)
                        .frame(width: max(2, width * min(1, Double(sample.appMemory) / total)))
                }
            }
            .frame(height: 8)
            Text("Lantern holds \(sample.appMemory.byteText) (blue), \(sample.modelMemory.byteText) of it the model. Grey is everything else on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func power(_ sample: MacSample) -> some View {
        if sample.battery != nil || sample.lowPower {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text("Power").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let battery = sample.battery {
                        Label("\(Int((battery.level * 100).rounded()))%\(battery.charging ? ", charging" : battery.onBattery ? ", on battery" : "")",
                              systemImage: battery.charging ? "battery.100.bolt" : "battery.50")
                            .font(Theme.readout(.subheadline))
                    }
                }
                Text(sample.lowPower
                     ? "Low Power Mode is on, so macOS holds the chip back and replies come more slowly. That is expected."
                     : "Replies draw more power while they are written. On battery, a long session will use some charge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chartRow(title: String, value: String, values: [Double], explain: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(value).font(Theme.readout(.subheadline))
            }
            Chart(Array(values.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("Second", point.offset), y: .value("Busy", point.element))
                    .foregroundStyle(Theme.accent.opacity(0.18))
                LineMark(x: .value("Second", point.offset), y: .value("Busy", point.element))
                    .foregroundStyle(Theme.accent)
            }
            .chartYScale(domain: 0 ... 1)
            .chartXScale(domain: 0 ... max(1, MacMetrics.window - 1))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { mark in
                    AxisGridLine()
                    AxisValueLabel { if let v = mark.as(Double.self) { Text("\(Int(v * 100))%") } }
                }
            }
            .frame(height: 54)
            Text(explain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// A line of recent values, 0 to 1, for the corner gauge.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(MacMetrics.window - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: start + step * CGFloat(index), y: size.height * (1 - CGFloat(min(1, max(0, value)))))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
        }
    }
}

/// The four thermal steps macOS reports, in words.
enum MacHeat {
    static func level(_ state: ProcessInfo.ThermalState?) -> Int {
        switch state {
        case .fair: 1
        case .serious: 2
        case .critical: 3
        default: 0
        }
    }

    static func name(_ state: ProcessInfo.ThermalState?) -> String {
        switch state {
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        default: "Cool"
        }
    }

    static func color(_ state: ProcessInfo.ThermalState?) -> Color {
        switch state {
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        default: .green
        }
    }

    static func sentence(_ state: ProcessInfo.ThermalState?) -> String {
        switch state {
        case .fair: "Warming up, which is normal while replies are written."
        case .serious: "Hot enough that macOS is slowing things to cool down; replies will come more slowly."
        case .critical: "Very hot. macOS is slowing everything hard. Give it a minute before the next long reply."
        default: "Running cool."
        }
    }
}
#endif
