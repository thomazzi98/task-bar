import SwiftUI
import TaskBarCore

/// A headline number with a small caption.
struct UsageStatTile: View {
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
struct UsageBreakdownRow: View {
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
                Text(Formatting.compact(tokens))
                    .font(.system(size: 11))
                    .monospacedDigit()
                Text(Formatting.money(cost))
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
struct UsageSessionLine: View {
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
                Text(Formatting.compact(row.usage.total))
                    .font(.system(size: 12))
                    .monospacedDigit()
                Text(Formatting.money(row.cost))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
