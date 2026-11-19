import Foundation
import Testing
@testable import TaskBarCore

@Suite("Peripherals and drives")
struct PeripheralsTests {
    /// Trimmed output of `system_profiler SPBluetoothDataType -json` with a keyboard, a mouse,
    /// AirPods, a headset without a battery and a device that is not connected.
    static let profilerJSON = #"""
    {
      "SPBluetoothDataType" : [
        {
          "controller_properties" : {
            "controller_chipset" : "BCM_4387",
            "controller_state" : "attrib_On"
          },
          "device_connected" : [
            {
              "Magic Keyboard" : {
                "device_address" : "AA:BB:CC:DD:EE:01",
                "device_batteryLevelMain" : "85%",
                "device_minorType" : "Keyboard",
                "device_productID" : "0x0320"
              }
            },
            {
              "Magic Mouse" : {
                "device_address" : "AA:BB:CC:DD:EE:02",
                "device_batteryLevelMain" : "60%",
                "device_minorType" : "Mouse"
              }
            },
            {
              "Rafael's AirPods Pro" : {
                "device_address" : "AA:BB:CC:DD:EE:03",
                "device_batteryLevelLeft" : "80%",
                "device_batteryLevelRight" : "75%",
                "device_batteryLevelCase" : "40%",
                "device_minorType" : "Headphones"
              }
            },
            {
              "Desk Speaker" : {
                "device_address" : "AA:BB:CC:DD:EE:04",
                "device_minorType" : "Speaker"
              }
            }
          ],
          "device_not_connected" : [
            {
              "Old Trackpad" : {
                "device_address" : "AA:BB:CC:DD:EE:05",
                "device_batteryLevelMain" : "10%",
                "device_minorType" : "Trackpad"
              }
            }
          ]
        }
      ]
    }
    """#

    @Test func parsesBatteryLevelsOfConnectedDevices() {
        let devices = PeripheralParser.bluetoothDevices(profilerJSON: Data(Self.profilerJSON.utf8))

        #expect(devices.map(\.name) == ["Magic Keyboard", "Magic Mouse", "Rafael's AirPods Pro"])

        let keyboard = devices[0]
        #expect(keyboard.kind == .keyboard)
        #expect(keyboard.level == 85)
        #expect(keyboard.leftLevel == nil)

        let mouse = devices[1]
        #expect(mouse.kind == .mouse)
        #expect(mouse.level == 60)

        let airPods = devices[2]
        #expect(airPods.kind == .headphones)
        #expect(airPods.leftLevel == 80)
        #expect(airPods.rightLevel == 75)
        #expect(airPods.caseLevel == 40)
        #expect(airPods.level == nil)
    }

    @Test func skipsDevicesWithoutABatteryAndDisconnectedOnes() {
        let devices = PeripheralParser.bluetoothDevices(profilerJSON: Data(Self.profilerJSON.utf8))
        #expect(!devices.contains { $0.name == "Desk Speaker" })
        #expect(!devices.contains { $0.name == "Old Trackpad" })
    }

    @Test func toleratesMalformedInput() {
        #expect(PeripheralParser.bluetoothDevices(profilerJSON: Data("not json".utf8)).isEmpty)
        #expect(PeripheralParser.bluetoothDevices(profilerJSON: Data(#"{"SPBluetoothDataType": []}"#.utf8)).isEmpty)
    }

    @Test func readsPercentages() {
        #expect(PeripheralParser.percent("85%") == 85)
        #expect(PeripheralParser.percent(" 40 % ") == 40)
        #expect(PeripheralParser.percent("Fully charged") == nil)
        #expect(PeripheralParser.percent(nil) == nil)
        #expect(PeripheralParser.percent(120) == 100)
        #expect(PeripheralParser.percent(-5) == 0)
        #expect(PeripheralParser.percent(42) == 42)
    }

    @Test func infersKindFromTypeOrName() {
        #expect(PeripheralKind(minorType: "Trackpad", name: "Force Touch") == .trackpad)
        #expect(PeripheralKind(minorType: nil, name: "Magic Trackpad") == .trackpad)
        #expect(PeripheralKind(minorType: nil, name: "AirPods Max") == .headphones)
        #expect(PeripheralKind(minorType: "Mouse", name: "Logi") == .mouse)
        #expect(PeripheralKind(minorType: nil, name: "Gadget") == .other)
    }

    @Test func mergesSourcesByNameKeepingTheMoreDetailedReading() {
        let registry = [
            PeripheralDevice(name: "Magic Keyboard", kind: .other, level: 84),
            PeripheralDevice(name: "Magic Mouse", kind: .other, level: 60)
        ]
        let profiler = [
            PeripheralDevice(name: "Magic Keyboard", kind: .keyboard, level: 85),
            PeripheralDevice(name: "Rafael's AirPods Pro", kind: .headphones, leftLevel: 80, rightLevel: 75, caseLevel: 40),
            PeripheralDevice(name: "Empty", kind: .other)
        ]

        let merged = PeripheralMerge.merge(profiler, registry)

        #expect(merged.map(\.name) == ["Magic Keyboard", "Magic Mouse", "Rafael's AirPods Pro"])
        // Same detail in both sources: the first list (profiler) wins, and keeps its kind.
        #expect(merged[0].level == 85)
        #expect(merged[0].kind == .keyboard)
        // The IORegistry reading fills in the device the profiler did not report.
        #expect(merged[1].level == 60)
    }

    @Test func prefersTheReadingWithMoreLevels() {
        let sparse = PeripheralDevice(name: "Buds", kind: .headphones, level: 50)
        let detailed = PeripheralDevice(name: "buds", kind: .other, leftLevel: 90, rightLevel: 88)

        let merged = PeripheralMerge.merge([sparse], [detailed])

        #expect(merged.count == 1)
        #expect(merged[0].leftLevel == 90)
        #expect(merged[0].kind == .headphones)
        #expect(merged[0].lowestLevel == 88)
    }

    @Test func arrangesVolumesWithRootFirstThenExternal() {
        let root = MountedVolume(
            url: URL(fileURLWithPath: "/"), name: "Macintosh HD", formatName: "APFS",
            totalBytes: 500, availableBytes: 200, isRoot: true
        )
        let data = MountedVolume(
            url: URL(fileURLWithPath: "/System/Volumes/Data"), name: "Data",
            totalBytes: 500, availableBytes: 200
        )
        let stick = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Zeta Stick"), name: "Zeta Stick",
            totalBytes: 64, availableBytes: 10, isRemovable: true, isEjectable: true, isInternal: false
        )
        let camera = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/alpha SSD"), name: "alpha SSD",
            totalBytes: 1_000, availableBytes: 400, isEjectable: true, isInternal: false
        )
        let recovery = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Recovery"), name: "Recovery",
            totalBytes: 10, availableBytes: 5
        )
        let empty = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Empty"), name: "Empty", totalBytes: 0, availableBytes: 0
        )
        let duplicate = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Zeta Stick/"), name: "Zeta Stick",
            totalBytes: 64, availableBytes: 10, isRemovable: true, isEjectable: true, isInternal: false
        )

        let arranged = VolumeArrangement.arrange([stick, recovery, data, empty, camera, root, duplicate])

        #expect(arranged.map(\.name) == ["Macintosh HD", "alpha SSD", "Zeta Stick", "Recovery"])
    }

    @Test func reportsUsedFractionOfAVolume() {
        let volume = MountedVolume(url: URL(fileURLWithPath: "/Volumes/X"), name: "X", totalBytes: 200, availableBytes: 50)
        #expect(volume.usedFraction == 0.75)
        let empty = MountedVolume(url: URL(fileURLWithPath: "/Volumes/Y"), name: "Y", totalBytes: 0, availableBytes: 0)
        #expect(empty.usedFraction == 0)
    }
}
