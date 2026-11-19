import SwiftUI
import TaskBarCore

/// Listening TCP ports on the System tab. Doubles as a light database monitor: Postgres, MySQL,
/// MongoDB and Redis show up here when they run.
struct PortsSection: View {
    @Environment(PortsViewModel.self) private var ports

    @AppStorage("system.portsExpanded") private var isExpanded = true

    var body: some View {
        @Bindable var ports = ports
        CollapsibleSection(title: "Ports", count: ports.visiblePorts.count, isExpanded: $isExpanded) {
            SegmentedControl(
                options: PortFilter.allCases.map { ($0, $0.label) },
                selection: $ports.filter
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 3)

            if ports.ports.isEmpty {
                SectionMessage(text: "No listening ports.")
            } else if ports.visiblePorts.isEmpty {
                SectionMessage(text: "Nothing in this filter.")
            } else {
                ForEach(ports.visiblePorts) { port in PortRow(port: port) }
            }

            if let notice = ports.notice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
    }
}

private extension PortFilter {
    var label: String {
        switch self {
        case .all: "All"
        case .development: "Dev"
        case .databases: "Databases"
        }
    }
}

private struct PortRow: View {
    let port: ListeningPort

    @Environment(PortsViewModel.self) private var ports
    @State private var isHovered = false

    var body: some View {
        let service = port.service
        HStack(spacing: 7) {
            Image(systemName: service?.isDatabase == true ? "cylinder" : "network")
                .font(.system(size: 11.5))
                .foregroundStyle(service?.isDatabase == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(String(port.port))
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                    Text(service?.label ?? port.command)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if port.isLoopbackOnly {
                        Chip(text: "local")
                    }
                }
                Text("\(port.command) · PID \(String(port.pid))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if service?.isWebLike == true {
                PillButton(title: "Open", symbol: "arrow.up.right.square") {
                    Opener.openLocalhost(port: Int(port.port))
                }
                .help("Open http://localhost:\(String(port.port))")
            }
            trailingControl
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .hoverHighlight()
        .contextMenu {
            Button("Copy Port") { Opener.copyToPasteboard(String(port.port)) }
            Button("Copy PID") { Opener.copyToPasteboard(String(port.pid)) }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch ports.block(for: port) {
        case .protectedProcess:
            Image(systemName: "lock")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .frame(width: 26, height: 24)
                .help("System process or TaskBar itself — cannot be stopped from here")
        case .ownedByOtherUser(let owner):
            IconButton(symbol: "stop.circle", help: "Owned by \(owner)") {}
                .disabled(true)
                .opacity(0.35)
        case nil:
            if ports.stubborn.contains(port.id) {
                Chip(text: "Still running", tint: .orange)
                ConfirmButton(symbol: "bolt.fill", confirmTitle: "Force quit?", help: "Force quit (SIGKILL)") {
                    ports.forceQuit(port)
                }
            } else {
                ConfirmButton(symbol: "stop.circle", confirmTitle: "Stop?", help: "Stop \(port.command) (SIGTERM)") {
                    ports.stop(port)
                }
                .opacity(isHovered ? 1 : 0.25)
            }
        }
    }
}
