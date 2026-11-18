import CoreServices
import Foundation

/// Calls a handler whenever anything changes inside a directory tree.
///
/// Built on FSEvents, which is kernel-driven: while nothing changes the watcher costs nothing,
/// which is what lets the app react instantly without polling.
public final class DirectoryWatcher: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "taskbar.directory-watcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// Returns `nil` when the directory does not exist or the stream cannot be created.
    public init?(url: URL, latency: TimeInterval = 0.15, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        stop()
    }

    /// Stops delivering events. Safe to call more than once.
    public func stop() {
        lock.lock()
        let active = stream
        stream = nil
        lock.unlock()

        guard let active else { return }
        FSEventStreamStop(active)
        FSEventStreamInvalidate(active)
        FSEventStreamRelease(active)
    }
}
