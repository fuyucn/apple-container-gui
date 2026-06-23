import SwiftUI
import Charts
import Core

/// The Activity Monitor section (content column of `RootView`'s single split).
///
/// Renders a macOS `Table` of live per-container resource usage plus a synthetic
/// "Containers" aggregate row, and a row of four sparkline summary cards (CPU /
/// Memory / Network / Disk) driven by the selected row — or the aggregate when
/// nothing is selected. All numbers + history come from the already-unit-tested
/// `ActivityMonitorViewModel`; this view holds no business logic. Polling starts
/// on appear (~2s interval) and stops on disappear, so the streaming `Task` never
/// outlives the section. Degrades to a calm empty state when nothing is running.
@MainActor
struct ActivityMonitorView: View {
    @Bindable var viewModel: ActivityMonitorViewModel

    /// Polling cadence, supplied by the caller from `AppSettings`. Defaults to
    /// 2s, which keeps cumulative-counter deltas meaningful.
    var pollInterval: Duration = .seconds(2)

    /// Sentinel id for the synthetic aggregate row in the `Table` selection.
    private static let aggregateID = "__aggregate__"

    /// The selected table row's id. `nil` (or the aggregate sentinel) shows the
    /// aggregate in the cards.
    @State private var selection: String?

    var body: some View {
        content
            .navigationTitle("Activity Monitor")
            .frame(minWidth: 280)
            .task {
                viewModel.startPolling(interval: pollInterval)
            }
            .onDisappear {
                viewModel.stopPolling()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.rows.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                table
                Divider()
                cards
                    .padding(12)
            }
        }
    }

    /// Calm empty state. Distinguishes "runtime unavailable" (last poll failed)
    /// from "nothing running". Never crashes when `container` is missing.
    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.lastError == nil ? "No Running Containers" : "Container Runtime Unavailable",
            systemImage: "chart.line.uptrend.xyaxis",
            description: Text(
                viewModel.lastError == nil
                    ? "Start a container to see live CPU, memory, network, and disk usage."
                    : "Could not reach the container runtime. Make sure the service is running."
            )
        )
    }

    // MARK: - Table

    private var table: some View {
        Table(tableRows, selection: $selection) {
            TableColumn("Name") { row in
                Text(row.name)
                    .fontWeight(row.isAggregate ? .semibold : .regular)
                    .lineLimit(1)
            }
            TableColumn("CPU %") { row in
                Text(Self.percent(row.metrics.cpuPercent))
                    .monospacedDigit()
            }
            TableColumn("Memory") { row in
                Text(Self.bytes(row.metrics.memoryBytes))
                    .monospacedDigit()
            }
            TableColumn("Network (KB/s)") { row in
                Text(Self.rate(row.metrics.netKBs))
                    .monospacedDigit()
            }
            TableColumn("Disk (KB/s)") { row in
                Text(Self.rate(row.metrics.diskKBs))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Cards

    private var cards: some View {
        let metrics = selectedMetrics
        let history = selectedHistory
        return HStack(spacing: 12) {
            SparklineCard(
                title: "CPU",
                value: Self.percent(metrics.cpuPercent),
                points: history.cpuPercent,
                tint: .blue
            )
            SparklineCard(
                title: "Memory",
                value: Self.bytes(metrics.memoryBytes),
                points: history.memoryBytes,
                tint: .purple
            )
            SparklineCard(
                title: "Network",
                value: Self.rate(metrics.netKBs) + " KB/s",
                points: history.netKBs,
                tint: .green
            )
            SparklineCard(
                title: "Disk",
                value: Self.rate(metrics.diskKBs) + " KB/s",
                points: history.diskKBs,
                tint: .orange
            )
        }
    }

    // MARK: - Selection resolution

    /// Display rows: the aggregate "Containers" row first, then per-container rows.
    private var tableRows: [DisplayRow] {
        var out: [DisplayRow] = []
        if let aggregate = viewModel.aggregate {
            out.append(DisplayRow(id: Self.aggregateID, name: "Containers", metrics: aggregate, isAggregate: true))
        }
        out.append(contentsOf: viewModel.rows.map {
            DisplayRow(id: $0.id, name: $0.id, metrics: $0.metrics, isAggregate: false)
        })
        return out
    }

    /// The metrics shown in the cards: the selected container, else the aggregate.
    private var selectedMetrics: ActivityMonitorViewModel.ComputedMetrics {
        if let row = selectedContainerRow { return row.metrics }
        return viewModel.aggregate ?? .init()
    }

    /// The history shown in the cards. The aggregate has no stored history, so
    /// nothing-selected falls back to the first row's history if present.
    private var selectedHistory: ActivityMonitorViewModel.MetricHistory {
        if let row = selectedContainerRow { return row.history }
        return viewModel.rows.first?.history ?? .init()
    }

    /// The selected per-container row, or nil when nothing / the aggregate is
    /// selected (or the selection has since disappeared from the live list).
    private var selectedContainerRow: ActivityMonitorViewModel.ActivityRow? {
        guard let selection, selection != Self.aggregateID else { return nil }
        return viewModel.rows.first { $0.id == selection }
    }

    // MARK: - Formatting (view-layer only)

    private static func percent(_ v: Double) -> String {
        String(format: "%.1f%%", v)
    }

    private static func rate(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    private static func bytes(_ v: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(v))
    }
}

/// A flattened, `Identifiable` table row (aggregate or per-container) so the
/// macOS `Table` can render and select uniformly.
private struct DisplayRow: Identifiable {
    let id: String
    let name: String
    let metrics: ActivityMonitorViewModel.ComputedMetrics
    let isAggregate: Bool
}

/// A single summary card: a title, the current value, and a Swift Charts
/// sparkline over the metric's rolling history. Falls back to a flat baseline
/// when there is not yet enough history to draw a line.
@MainActor
private struct SparklineCard: View {
    let title: String
    let value: String
    let points: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            sparkline
                .frame(height: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var sparkline: some View {
        if points.count >= 2 {
            Chart(Array(points.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Sample", index),
                    y: .value("Value", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
        } else {
            // Calm placeholder until two samples have accumulated.
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(0.08))
        }
    }

    /// A y-domain that always includes 0 and gives a flat line some headroom so
    /// a constant series doesn't render as a degenerate zero-height chart.
    private var yDomain: ClosedRange<Double> {
        let maxValue = points.max() ?? 0
        let upper = maxValue <= 0 ? 1 : maxValue * 1.15
        return 0...upper
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin shipped only with
// full Xcode, not the Command Line Tools `swift build` compile gate. Gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// seeded view model guarantees the preview renders with real history.
#if ENABLE_PREVIEWS
#Preview("Activity Monitor - populated") {
    NavigationStack {
        ActivityMonitorView(viewModel: ActivityMonitorPreviewData.seededViewModel())
    }
}

#Preview("Activity Monitor - empty") {
    NavigationStack {
        ActivityMonitorView(viewModel: ActivityMonitorViewModel(service: ActivityMonitorPreviewData.emptyService))
    }
}
#endif
