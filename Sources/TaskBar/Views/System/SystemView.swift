import SwiftUI
import TaskBarCore

/// The System tab: machine vitals, open apps, top processes and Docker containers.
struct SystemView: View {
    @Environment(SystemViewModel.self) private var system
    @Environment(AppState.self) private var appState

    @AppStorage("system.appsExpanded") private var isAppsExpanded = true
    @AppStorage("system.processesExpanded") private var isProcessesExpanded = false
    @AppStorage("system.containersExpanded") private var isContainersExpanded = true

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VitalsView(snapshot: system.snapshot, cpuHistory: system.cpuHistory)
                    .padding(.horizontal, Design.gutter)

                DevicesSection()
                DrivesSection()

                CollapsibleSection(title: "Apps", count: system.apps.count, isExpanded: $isAppsExpanded) {
                    ForEach(system.apps) { app in AppRow(app: app) }
                }

                CollapsibleSection(title: "Top processes", count: nil, isExpanded: $isProcessesExpanded) {
                    processSortPicker
                    ForEach(system.processes) { process in ProcessRow(process: process) }
                }

                PortsSection()

                containersSection
            }
            .padding(.vertical, 10)
        }
        .onChange(of: system.actionMessage) { _, message in
            guard let message else { return }
            appState.showToast(message)
            system.clearActionMessage()
        }
    }

    private var processSortPicker: some View {
        @Bindable var system = system
        return SegmentedControl(
            options: ProcessSortKey.allCases.map { ($0, $0.label) },
            selection: $system.processSort
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
        .onChange(of: system.processSort) { system.resortProcesses() }
    }

    @ViewBuilder
    private var containersSection: some View {
        CollapsibleSection(
            title: "Containers",
            count: system.isDockerAvailable ? system.runningContainerCount : nil,
            isExpanded: $isContainersExpanded
        ) {
            if !system.isDockerAvailable {
                SectionMessage(text: "Docker is not running.")
            } else if system.containers.isEmpty {
                SectionMessage(text: "No containers.")
            } else {
                ForEach(system.containers) { container in
                    ContainerRow(container: container, usage: system.containerUsage[container.id])
                }
            }
        }
    }
}

// MARK: - Vitals

private struct VitalsView: View {
    let snapshot: SystemSnapshot?
    let cpuHistory: [Double]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                cpuCard
                memoryCard
            }
            HStack(spacing: 8) {
                if let disk = snapshot?.disk {
                    StatTile(
                        symbol: "internaldrive",
                        title: "Disk",
                        value: Formatting.bytes(disk.availableBytes),
                        caption: "free of \(Formatting.bytes(disk.totalBytes))"
                    )
                }
                if let battery = snapshot?.battery {
                    StatTile(
                        symbol: battery.isCharging ? "battery.100.bolt" : "battery.75",
                        title: "Battery",
                        value: "\(battery.percent)%",
                        caption: batteryCaption(battery)
                    )
                }
                StatTile(
                    symbol: "arrow.up.arrow.down",
                    title: "Network",
                    value: "↓ " + Formatting.rate(snapshot?.network?.bytesInPerSecond ?? 0),
                    caption: "↑ " + Formatting.rate(snapshot?.network?.bytesOutPerSecond ?? 0)
                )
            }
            if let snapshot {
                HStack(spacing: 5) {
                    Text("Up \(Formatting.uptime(snapshot.uptime))")
                    if snapshot.thermal != .nominal {
                        Text("·")
                        Label("Thermal state: \(snapshot.thermal.label.lowercased())", systemImage: "thermometer.medium")
                            .labelStyle(CompactLabelStyle())
                            .foregroundStyle(snapshot.thermal == .fair ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
            }
        }
    }

    private var cpuCard: some View {
        let load = snapshot?.cpu
        let fraction = load?.overall ?? 0
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Label("CPU", systemImage: "cpu").labelStyle(CompactLabelStyle())
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(load == nil ? "—" : Formatting.percent(fraction))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Sparkline(values: cpuHistory, tint: Design.loadColor(fraction))
                .frame(height: 26)
            // One thin bar per core shows whether load is spread out or pinned to a few cores.
            HStack(spacing: 1.5) {
                ForEach(Array((load?.perCore ?? []).enumerated()), id: \.offset) { _, core in
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            Rectangle().fill(Color.primary.opacity(0.08))
                            Rectangle().fill(Design.loadColor(core)).frame(height: proxy.size.height * min(max(core, 0.04), 1))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 1))
                }
            }
            .frame(height: 12)
        }
    }

    private var memoryCard: some View {
        let memory = snapshot?.memory
        let fraction = memory?.usedFraction ?? 0
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Memory", systemImage: "memorychip").labelStyle(CompactLabelStyle())
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(memory == nil ? "—" : Formatting.percent(fraction))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            UsageBar(fraction: fraction, tint: pressureColor(memory?.pressure), height: 6)
                .padding(.vertical, 4)
            if let memory {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Formatting.bytes(memory.usedBytes)) of \(Formatting.bytes(memory.totalBytes))")
                    HStack(spacing: 5) {
                        Circle().fill(pressureColor(memory.pressure)).frame(width: 5, height: 5)
                        Text("Pressure \(memory.pressure.label.lowercased())")
                        if memory.swapUsedBytes > 0 {
                            Text("· Swap \(Formatting.bytes(memory.swapUsedBytes))")
                        }
                    }
                    .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func pressureColor(_ pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .critical: .red
        case .warning: .orange
        default: .accentColor
        }
    }

    private func batteryCaption(_ battery: BatteryStatus) -> String {
        if let minutes = battery.minutesRemaining {
            let time = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
            return battery.isCharging ? "\(time) to full" : "\(time) left"
        }
        return battery.isCharging ? "Charging" : battery.isOnACPower ? "Plugged in" : "On battery"
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

private struct StatTile: View {
    let symbol: String
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Label(title, systemImage: symbol).labelStyle(CompactLabelStyle())
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

// MARK: - Sections

struct CollapsibleSection<Content: View>: View {
    let title: String
    let count: Int?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 1) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title.uppercased()).kerning(0.4)
                    if let count { Text("\(count)").foregroundStyle(.tertiary) }
                    Spacer()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded { content }
        }
        .padding(.horizontal, 6)
    }
}

/// CPU and memory figures aligned in fixed-width columns.
private struct UsageColumns: View {
    let cpuPercent: Double?
    let memoryBytes: UInt64

    var body: some View {
        HStack(spacing: 6) {
            Text(cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle((cpuPercent ?? 0) >= 80 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(memoryBytes > 0 ? Formatting.bytes(memoryBytes) : "—")
                .frame(width: 58, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }
}

private struct AppRow: View {
    let app: RunningAppUsage

    @Environment(SystemViewModel.self) private var system
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)

            Text(app.name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 4)
            UsageColumns(cpuPercent: app.usage.cpuPercent, memoryBytes: app.usage.memoryBytes)
            ConfirmButton(symbol: "xmark.circle", confirmTitle: "Quit?", help: "Quit \(app.name)") {
                system.quit(app, force: false)
            }
            .opacity(isHovered ? 1 : 0.25)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .onHover { isHovered = $0 }
        .hoverHighlight()
        .contextMenu {
            Button("Quit \(app.name)") { system.quit(app, force: false) }
            Button("Force Quit \(app.name)", role: .destructive) { system.quit(app, force: true) }
        }
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage

    @Environment(SystemViewModel.self) private var system
    @State private var isHovered = false

    var body: some View {
        let isProtected = system.isProtected(process)
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text(process.name.isEmpty ? "(unnamed)" : process.name).font(.system(size: 12.5)).lineLimit(1)
                Text("PID \(String(process.pid))").font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer(minLength: 4)
            UsageColumns(cpuPercent: process.cpuPercent, memoryBytes: process.memoryBytes)
            if isProtected {
                Image(systemName: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .frame(width: 26, height: 24)
                    .help("System process — cannot be stopped from here")
            } else {
                ConfirmButton(symbol: "xmark.circle", confirmTitle: "Stop?", help: "Ask \(process.name) to quit") {
                    system.terminate(process, force: false)
                }
                .opacity(isHovered ? 1 : 0.25)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .onHover { isHovered = $0 }
        .hoverHighlight()
        .contextMenu {
            if !isProtected {
                Button("Terminate (SIGTERM)") { system.terminate(process, force: false) }
                Button("Force Kill (SIGKILL)", role: .destructive) { system.terminate(process, force: true) }
            }
            Button("Copy PID") { Opener.copyToPasteboard(String(process.pid)) }
        }
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let usage: DockerUsage?

    @Environment(SystemViewModel.self) private var system

    var body: some View {
        let isBusy = system.busyContainers.contains(container.id)
        HStack(spacing: 7) {
            Circle()
                .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.system(size: 12.5)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(container.isRunning ? container.status : container.state.capitalized)
                        .lineLimit(1)
                    ForEach(container.publishedPorts.prefix(3), id: \.self) { port in
                        Button(":\(String(port))") { Opener.openLocalhost(port: port) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Open http://localhost:\(String(port))")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)

            if container.isRunning {
                UsageColumns(cpuPercent: usage?.cpuPercent, memoryBytes: usage?.memoryBytes ?? 0)
            }
            if isBusy {
                ProgressView().controlSize(.small).frame(width: 52, height: 24)
            } else if container.isRunning {
                IconButton(symbol: "arrow.clockwise", help: "Restart") { system.perform(.restart, on: container) }
                IconButton(symbol: "stop.circle", help: "Stop") { system.perform(.stop, on: container) }
            } else {
                IconButton(symbol: "play.circle", help: "Start") { system.perform(.start, on: container) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .hoverHighlight()
        .contextMenu {
            Button("Copy Name") { Opener.copyToPasteboard(container.name) }
            Button("Copy Image") { Opener.copyToPasteboard(container.image) }
        }
    }
}
