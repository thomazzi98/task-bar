import Darwin
import Foundation

/// Static facts about a running process.
public struct ProcessDetails: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var userID: UInt32
    public var name: String
    /// Controlling terminal device, e.g. `/dev/ttys003`. `nil` for processes without one.
    public var ttyPath: String?
}

/// CPU time and memory consumed by a process so far.
public struct ProcessResourceUsage: Equatable, Sendable {
    public var cpuTimeNanoseconds: UInt64
    /// Physical footprint, the figure Activity Monitor reports as "Memory".
    public var memoryBytes: UInt64
}

/// Thin, allocation-light wrappers over `libproc`. None of these need special privileges for
/// processes owned by the current user.
public enum ProcessInspector {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func allPIDs() -> [Int32] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        // Leave headroom for processes spawned between the two calls.
        var pids = [Int32](repeating: 0, count: capacity + 32)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    public static func details(of pid: Int32) -> ProcessDetails? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        // The name is already in the record just fetched: prefer the long field (up to 32
        // bytes) and fall back to the short command name.
        let longName = withUnsafeBytes(of: info.pbi_name) { string(fromNullTerminated: Array($0)) }
        let name = longName.isEmpty
            ? withUnsafeBytes(of: info.pbi_comm) { string(fromNullTerminated: Array($0)) }
            : longName

        return ProcessDetails(
            pid: pid,
            parentPID: Int32(bitPattern: info.pbi_ppid),
            userID: info.pbi_uid,
            name: name,
            ttyPath: ttyPath(device: info.e_tdev)
        )
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        details(of: pid)?.parentPID
    }

    /// The chain of parent process IDs, nearest first, stopping before `launchd`.
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < limit, let parent = parentPID(of: current), parent > 1, !chain.contains(parent) {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    public static func name(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(fromNullTerminated: buffer)
    }

    /// The executable's file name. Unlike `name(of:)`, it is not cut off at 32 bytes, so
    /// "Google Chrome Helper (Renderer)" stays whole. Costs one more system call.
    public static func fullName(of pid: Int32) -> String? {
        guard let path = executablePath(of: pid) else { return name(of: pid) }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return fileName.isEmpty ? name(of: pid) : fileName
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(fromNullTerminated: buffer)
    }

    public static func resourceUsage(of pid: Int32) -> ProcessResourceUsage? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        let ticks = usage.ri_user_time + usage.ri_system_time
        return ProcessResourceUsage(
            cpuTimeNanoseconds: ticks * timebase.numerator / timebase.denominator,
            memoryBytes: usage.ri_phys_footprint
        )
    }

    /// Sends a signal to a process. Returns `false` when the kernel refuses (for example
    /// because the process belongs to another user).
    @discardableResult
    public static func send(signal: Int32, to pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, signal) == 0
    }

    // MARK: Private

    /// `proc_pid_rusage` reports CPU time in Mach absolute-time units, which only equal
    /// nanoseconds on Intel.
    private static let timebase: (numerator: UInt64, denominator: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    private static func string(fromNullTerminated buffer: [UInt8]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func ttyPath(device: UInt32) -> String? {
        guard device != UInt32.max, device != 0,
              let name = devname(dev_t(bitPattern: device), S_IFCHR)
        else { return nil }
        return "/dev/" + String(cString: name)
    }
}
