import SwiftUI
import TaskBarCore

/// Shared metrics and colours.
enum Design {
    static let panelWidth: CGFloat = 420
    static let gutter: CGFloat = 12
    static let rowRadius: CGFloat = 7

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .needsApproval, .needsAnswer: .orange
        case .working: .blue
        case .finished: .green
        case .idle: .secondary
        }
    }

    static func color(for priority: TaskPriority) -> Color {
        switch priority {
        case .none: .secondary
        case .low: .blue
        case .medium: .orange
        case .high: .red
        }
    }

    /// Green, amber or red depending on how full a resource is.
    static func loadColor(_ fraction: Double) -> Color {
        fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor
    }
}

extension Color {
    /// Parses `#RRGGBB`.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Hover

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : isHovered ? 0.06 : 0))
            )
            .onHover { isHovered = $0 }
    }
}

extension View {
    /// Subtle background shown while the pointer is over the view.
    func hoverHighlight(cornerRadius: CGFloat = Design.rowRadius, isSelected: Bool = false) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isSelected: isSelected))
    }
}

// MARK: - Buttons

/// A compact toolbar button showing only a symbol.
struct IconButton: View {
    let symbol: String
    var help = ""
    var isActive = false
    var tint: Color = .accentColor
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isActive ? 0.10 : isHovered ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help.isEmpty ? symbol : help)
    }
}

/// A small text button with an optional symbol, used for secondary actions.
struct PillButton: View {
    let title: String
    var symbol: String?
    var tint: Color = .accentColor
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .background(
                Capsule().fill(isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A destructive action that must be clicked twice: the first click arms it for a few seconds.
struct ConfirmButton: View {
    /// How the button looks before it is armed. Once armed it is always a red pill labelled `confirmTitle`.
    enum Look: Equatable {
        /// A bare icon with a tooltip, for rows.
        case icon
        /// A labelled pill, for footers.
        case pill(title: String)
    }

    let symbol: String
    let confirmTitle: String
    var help = ""
    var look: Look = .icon
    let action: () -> Void

    @State private var isArmed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isArmed {
                PillButton(title: confirmTitle, tint: .red, isProminent: true) {
                    disarm()
                    action()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                switch look {
                case .icon:
                    IconButton(symbol: symbol, help: help, action: arm)
                case .pill(let title):
                    PillButton(title: title, symbol: symbol, tint: .secondary, action: arm)
                        .help(help)
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: isArmed)
        .onDisappear { disarmTask?.cancel() }
    }

    private func arm() {
        isArmed = true
        disarmTask?.cancel()
        disarmTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isArmed = false
        }
    }

    private func disarm() {
        disarmTask?.cancel()
        isArmed = false
    }
}

/// The round completion checkbox used by tasks.
struct Checkbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Mark as not done" : "Mark as done")
    }
}

/// A switch drawn in SwiftUI. The system switch turns grey whenever its window is not key,
/// which is most of the time for a popover opened by hovering.
struct SwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 4)
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.18)))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                            .padding(2)
                    }
                    .animation(.easeOut(duration: 0.14), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A compact segmented control that looks the same whether or not its window is key.
struct SegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 21)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(Color.primary.opacity(isSelected ? 0.12 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7.5, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}

extension View {
    /// A menu whose label is drawn exactly as given, without the system button chrome.
    func plainMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

// MARK: - Small display pieces

struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
            .lineLimit(1)
    }
}

/// A horizontal meter.
struct UsageBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// A tiny line chart of values in `0...1`.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            if values.count > 1 {
                let step = proxy.size.width / CGFloat(values.count - 1)
                let points = values.enumerated().map { index, value in
                    CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - min(max(value, 0), 1)))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: proxy.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.14))

                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message = ""

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An inline notice with an optional dismiss button.
struct NoticeBanner: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 1.5)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
    }
}

/// The dim line that stands in for a list with nothing to show, such as "No drives.".
struct SectionMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// The bar at the top of a detail screen: a back button plus trailing controls.
struct BackBar<Trailing: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold))
                    Text(title).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, Design.gutter)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// A text field that adds an item on Return and stays focused for the next one.
struct QuickAddField: View {
    let placeholder: String
    var symbol = "plus"
    /// When `true`, the field takes focus whenever the popover asks for its primary field.
    var isPrimary = false
    let onSubmit: (String) -> Void

    @Environment(AppState.self) private var appState
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isFocused ? 0.07 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.45 : 0), lineWidth: 1)
        )
        .onChange(of: appState.focusRequest, initial: true) {
            if isPrimary, appState.isPanelVisible { isFocused = true }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        text = ""
        isFocused = true
    }
}

/// A confirmation row shown in place of a destructive action, such as deleting a folder.
struct InlineConfirmBar: View {
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            PillButton(title: "Cancel", tint: .secondary, action: onCancel)
            PillButton(title: confirmTitle, tint: .red, isProminent: true, action: onConfirm)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

/// The storage warning shown at the top of a tab, with a dismiss button. Shows nothing when there is none.
struct StorageNotice: View {
    let warning: String?
    let onDismiss: () -> Void

    var body: some View {
        if let warning {
            NoticeBanner(text: warning, onDismiss: onDismiss)
                .padding(.horizontal, Design.gutter)
                .padding(.bottom, 6)
        }
    }
}

/// A titled group of content: a small uppercase heading, an optional detail beside it, then the
/// content itself.
struct SectionBlock<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An icon and text set tighter than the default label.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2.5) {
            configuration.icon.font(.system(size: 8.5))
            configuration.title
        }
    }
}
