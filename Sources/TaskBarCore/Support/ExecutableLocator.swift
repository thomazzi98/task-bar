import Foundation

/// Picks the command-line tools that CLI-backed features run.
public enum ExecutableLocator {
    /// The first candidate that exists and is executable, in the order given.
    public static func first(in candidates: [URL], fileManager: FileManager = .default) -> URL? {
        candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
