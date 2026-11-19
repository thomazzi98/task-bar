import Darwin

/// Byte searches over transcript bytes, done with libc rather than `Data`'s generic search.
enum ByteSearch {
    /// Index of the first newline at or after `start`, or nil.
    static func firstNewline(in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard start < bytes.count, let base = bytes.baseAddress else { return nil }
        guard let found = memchr(base + start, Int32(UInt8(ascii: "\n")), bytes.count - start) else { return nil }
        return UnsafeRawPointer(found) - base
    }

    /// Whether `needle` occurs anywhere in `bytes`.
    static func contains(_ needle: [UInt8], in bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, bytes.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, bytes.count, $0.baseAddress, $0.count) != nil }
    }
}
