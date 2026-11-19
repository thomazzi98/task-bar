import SwiftUI
import TaskBarCore

// MARK: - Devices

/// Battery levels of connected keyboards, mice, trackpads and headphones.
/// Hidden entirely when no connected device reports a battery.
struct DevicesSection: View {
    @Environment(PeripheralsViewModel.self) private var peripherals
    @AppStorage("system.devicesExpanded") private var isExpanded = true

    var body: some View {
        if !peripherals.devices.isEmpty {
            CollapsibleSection(title: "Devices", count: peripherals.devices.count, isExpanded: $isExpanded) {
                ForEach(peripherals.devices) { device in DeviceRow(device: device) }
            }
        } else if peripherals.needsBluetoothAccess {
            // Only when nothing else would show: explains why keyboard and mouse batteries are missing.
            CollapsibleSection(title: "Devices", count: nil, isExpanded: $isExpanded) {
                Text("Allow Bluetooth access in System Settings › Privacy & Security to see keyboard and mouse batteries.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: PeripheralDevice

    var body: some View {
        let lowest = device.lowestLevel ?? 0
        let tint: Color = lowest < Self.lowThreshold ? .red : .accentColor
        HStack(spacing: 8) {
            Image(systemName: device.kind.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.system(size: 12.5)).lineLimit(1)
                HStack(spacing: 6) {
                    UsageBar(fraction: Double(lowest) / 100, tint: tint, height: 4)
                    Text("\(lowest)%")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(lowest < Self.lowThreshold ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        .frame(width: 34, alignment: .trailing)
                    if device.isCharging {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green)
                    }
                }
                if let detail = partsText {
                    Text(detail)
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .hoverHighlight()
        .help(device.name)
    }

    private static let lowThreshold = 20

    /// `L 80% · R 75% · Case 40%`, for devices that report their parts separately.
    private var partsText: String? {
        let parts = [
            device.leftLevel.map { "L \($0)%" },
            device.rightLevel.map { "R \($0)%" },
            device.caseLevel.map { "Case \($0)%" }
        ].compactMap { $0 }
        // A single battery needs no caption: the bar and percentage already say it.
        guard device.level == nil, !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}

private extension PeripheralKind {
    var symbolName: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .headphones: "headphones"
        case .other: "battery.100"
        }
    }
}

// MARK: - Drives

/// Mounted volumes with their free space. A click opens the drive in Finder.
struct DrivesSection: View {
    @Environment(PeripheralsViewModel.self) private var peripherals
    @Environment(AppState.self) private var appState
    @AppStorage("system.drivesExpanded") private var isExpanded = true

    var body: some View {
        CollapsibleSection(title: "Drives", count: peripherals.volumes.count, isExpanded: $isExpanded) {
            if peripherals.volumes.isEmpty {
                Text("No drives.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(peripherals.volumes) { volume in DriveRow(volume: volume) }
            }
        }
        .onChange(of: peripherals.actionMessage) { _, message in
            guard let message else { return }
            appState.showToast(message)
            peripherals.clearActionMessage()
        }
    }
}

private struct DriveRow: View {
    let volume: MountedVolume

    @Environment(PeripheralsViewModel.self) private var peripherals

    var body: some View {
        let isEjecting = peripherals.ejectingVolumeIDs.contains(volume.id)
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(volume.name).font(.system(size: 12.5)).lineLimit(1)
                    if !volume.formatName.isEmpty {
                        Text(volume.formatName).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                UsageBar(fraction: volume.usedFraction, tint: Design.loadColor(volume.usedFraction), height: 4)
                Text("\(Formatting.bytes(volume.availableBytes)) free of \(Formatting.bytes(volume.totalBytes))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if volume.isEjectable {
                if isEjecting {
                    ProgressView().controlSize(.small).frame(width: 26, height: 24)
                } else {
                    IconButton(symbol: "eject", help: "Eject \(volume.name)") { peripherals.eject(volume) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { peripherals.open(volume) }
        .hoverHighlight()
        .help("Open \(volume.name) in Finder")
    }

    private var symbol: String {
        guard volume.isExternal else { return "internaldrive" }
        return volume.isRemovable ? "usb" : "externaldrive"
    }
}
