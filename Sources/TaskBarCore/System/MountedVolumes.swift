import Foundation

/// A mounted volume, as far as the Drives list needs it.
public struct MountedVolume: Equatable, Identifiable, Sendable {
    public var url: URL
    public var name: String
    public var formatName: String
    public var totalBytes: UInt64
    public var availableBytes: UInt64
    public var isRoot: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isInternal: Bool
    public var isLocal: Bool

    public init(
        url: URL,
        name: String,
        formatName: String = "",
        totalBytes: UInt64,
        availableBytes: UInt64,
        isRoot: Bool = false,
        isRemovable: Bool = false,
        isEjectable: Bool = false,
        isInternal: Bool = true,
        isLocal: Bool = true
    ) {
        self.url = url
        self.name = name
        self.formatName = formatName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isRoot = isRoot
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isLocal = isLocal
    }

    public var id: String { url.standardizedFileURL.path }

    /// Drives that were plugged in or are not on this Mac's own disks.
    public var isExternal: Bool { isRemovable || isEjectable || !isInternal || !isLocal }

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : min(max(1 - Double(availableBytes) / Double(totalBytes), 0), 1)
    }
}

/// Filtering and ordering of volumes, kept apart from the file system calls so it can be tested.
public enum VolumeArrangement {
    /// Drops the system's internal data mounts, empty volumes and duplicates, then orders the list:
    /// the root disk first, then external drives by name, then the other internal volumes by name.
    public static func arrange(_ volumes: [MountedVolume]) -> [MountedVolume] {
        var seen: Set<String> = []
        let unique = volumes.filter { volume in
            let path = volume.id
            guard !path.hasPrefix("/System/Volumes/"), volume.totalBytes > 0 else { return false }
            return seen.insert(path).inserted
        }
        return unique.sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            if lhs.isExternal != rhs.isExternal { return lhs.isExternal }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Reads the mounted volumes from the file system.
public enum VolumeProbe {
    public static func mounted() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsRootFileSystemKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else {
                return nil
            }
            // "For important usage" also counts purgeable space, which is what Finder reports.
            let available = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            return MountedVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                formatName: values.volumeLocalizedFormatDescription ?? "",
                totalBytes: UInt64(total),
                availableBytes: UInt64(max(available, 0)),
                isRoot: values.volumeIsRootFileSystem ?? false,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isInternal: values.volumeIsInternal ?? true,
                isLocal: values.volumeIsLocal ?? true
            )
        }
    }
}
