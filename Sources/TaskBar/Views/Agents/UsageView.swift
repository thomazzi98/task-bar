import SwiftUI
import TaskBarCore

/// Claude Code consumption over a period: totals, a chart over time, and where the tokens and
/// the estimated money went.
struct UsageView: View {
    @Environment(UsageViewModel.self) private var usage

    var body: some View {
        VStack(spacing: 0) {
            Picker("Period", selection: Bindable(usage).period) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Design.gutter)
            .padding(.vertical, 10)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content() -> some View {
        if let report = usage.report {
            if report.totals.messages == 0 {
                EmptyStateView(
                    symbol: "chart.bar",
                    title: "No usage in this period",
                    message: "Claude Code token use from the chosen period shows up here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        totals(report)
                        chart(report)
                        models(report)
                        projects(report)
                        topSessions(report)
                        Text("Estimated at API list prices. Claude subscriptions are billed differently.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Design.gutter)
                    .padding(.bottom, 12)
                }
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning transcripts…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Sections

    private func totals(_ report: UsageReport) -> some View {
        let total = report.totals
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            UsageStatTile(
                title: "Tokens",
                value: Formatting.compact(total.usage.total),
                detail: "\(Formatting.compact(total.usage.input)) in · \(Formatting.compact(total.usage.output)) out"
            )
            UsageStatTile(title: "Est. cost", value: Formatting.money(total.cost), detail: "at API list prices")
            UsageStatTile(title: "Messages", value: "\(total.messages)", detail: "assistant replies")
            UsageStatTile(
                title: "Cache hit",
                value: total.cacheHitRate.map { Formatting.percent($0) } ?? "—",
                detail: "\(Formatting.compact(total.usage.cacheRead)) read from cache"
            )
        }
    }

    private func chart(_ report: UsageReport) -> some View {
        let peak = Double(max(report.buckets.map { $0.usage.total }.max() ?? 0, 1))
        let first = report.buckets.first
        let last = report.buckets.last
        return SectionBlock(title: chartTitle(report)) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(report.buckets) { bucket in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(bucket.usage.total > 0 ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08))
                        .frame(height: max(3, 88 * Double(bucket.usage.total) / peak))
                        .frame(maxWidth: .infinity)
                        .help("\(label(for: bucket.start, hourly: report.bucketsAreHours)): \(Formatting.compact(bucket.usage.total)) tokens")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: 88, alignment: .bottom)

            HStack {
                if let first {
                    Text(label(for: first.start, hourly: report.bucketsAreHours))
                }
                Spacer(minLength: 4)
                if let last {
                    Text(label(for: last.start, hourly: report.bucketsAreHours))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    private func models(_ report: UsageReport) -> some View {
        SectionBlock(title: "By model") {
            ForEach(report.byModel) { row in
                UsageBreakdownRow(
                    name: UsageFormat.modelName(row.name),
                    tokens: row.usage.total,
                    cost: row.cost,
                    share: share(of: row.usage.total, in: report)
                )
            }
        }
    }

    private func projects(_ report: UsageReport) -> some View {
        SectionBlock(title: "By project") {
            ForEach(report.byProject.prefix(8)) { row in
                UsageBreakdownRow(
                    name: row.name,
                    tokens: row.usage.total,
                    cost: row.cost,
                    share: share(of: row.usage.total, in: report)
                )
            }
        }
    }

    private func topSessions(_ report: UsageReport) -> some View {
        SectionBlock(title: "Top sessions") {
            ForEach(report.topSessions) { row in
                UsageSessionLine(row: row)
            }
        }
    }

    // MARK: Helpers

    /// The chart covers the last 30 days when the period is all of history; it says so.
    private func chartTitle(_ report: UsageReport) -> String {
        if report.bucketsAreHours { return "Per hour" }
        return report.period == .all ? "Last 30 days" : "Per day"
    }

    private func share(of tokens: Int, in report: UsageReport) -> Double {
        Double(tokens) / Double(max(report.totals.usage.total, 1))
    }

    private func label(for date: Date, hourly: Bool) -> String {
        hourly
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}
