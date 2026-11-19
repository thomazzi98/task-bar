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
    }

    // MARK: Sections

    private func totals(_ report: UsageReport) -> some View {
        let total = report.totals
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            UsageStatTile(
                title: "Tokens",
                value: UsageFormat.compact(total.usage.total),
                detail: "\(UsageFormat.compact(total.usage.input)) in · \(UsageFormat.compact(total.usage.output)) out"
            )
            UsageStatTile(title: "Est. cost", value: UsageFormat.money(total.cost), detail: nil)
            UsageStatTile(title: "Messages", value: "\(total.messages)", detail: nil)
            UsageStatTile(
                title: "Cache hit",
                value: percent(total.cacheHitRate),
                detail: "\(UsageFormat.compact(total.usage.cacheRead)) read from cache"
            )
        }
    }

    private func chart(_ report: UsageReport) -> some View {
        let peak = Double(max(report.buckets.map { $0.usage.total }.max() ?? 0, 1))
        let first = report.buckets.first
        let last = report.buckets.last
        return usageSection(report.bucketsAreHours ? "Per hour" : "Per day") {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(report.buckets) { bucket in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(bucket.usage.total > 0 ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08))
                        .frame(height: max(3, 88 * Double(bucket.usage.total) / peak))
                        .frame(maxWidth: .infinity)
                        .help("\(label(for: bucket.start, hourly: report.bucketsAreHours)): \(UsageFormat.compact(bucket.usage.total)) tokens")
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
        usageSection("By model") {
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
        usageSection("By project") {
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
        usageSection("Top sessions") {
            ForEach(report.topSessions) { row in
                UsageSessionLine(row: row)
            }
        }
    }

    // MARK: Helpers

    private func usageSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func share(of tokens: Int, in report: UsageReport) -> Double {
        Double(tokens) / Double(max(report.totals.usage.total, 1))
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    private func label(for date: Date, hourly: Bool) -> String {
        hourly
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A headline number with a small caption.
private struct UsageStatTile: View {
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

/// One model or project: its name, tokens, cost and a bar showing its share of the total.
private struct UsageBreakdownRow: View {
    let name: String
    let tokens: Int
    let cost: Double?
    /// Fraction of the period's tokens, 0 to 1.
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(UsageFormat.compact(tokens))
                    .font(.system(size: 11))
                    .monospacedDigit()
                Text(UsageFormat.money(cost))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(3, proxy.size.width * share))
                }
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One of the busiest sessions: its project, how much it used and when it was last active.
private struct UsageSessionLine: View {
    let row: UsageReport.SessionRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.project)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(row.messages) messages")
                    Text("·")
                    Text(row.lastActivity, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageFormat.compact(row.usage.total))
                    .font(.system(size: 12))
                    .monospacedDigit()
                Text(UsageFormat.money(row.cost))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
