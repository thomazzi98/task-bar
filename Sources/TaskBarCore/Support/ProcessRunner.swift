import Foundation

/// What a finished command produced.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let standardOutput: Data
    public let standardError: Data
    /// `true` when the command was stopped for running past its timeout.
    public let timedOut: Bool

    public init(status: Int32, standardOutput: Data, standardError: Data, timedOut: Bool) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }
}

public enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "Could not start the process: \(reason)"
        }
    }
}

/// Runs a command to completion and captures its output.
///
/// Standard input and standard error go through temporary files, so the only pipe to drain is
/// standard output and no reader threads are needed. A command that runs past its timeout is
/// terminated, which closes its output and lets the read return.
public enum ProcessRunner {
    /// Runs the command on a utility queue, so the caller's task never blocks a cooperative thread.
    public static func run(
        executable: URL,
        arguments: [String],
        input: Data = Data(),
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try runBlocking(
                        executable: executable,
                        arguments: arguments,
                        input: input,
                        workingDirectory: workingDirectory,
                        timeout: timeout
                    )
                })
            }
        }
    }

    /// Runs the command on the calling thread and waits for it to finish or time out.
    public static func runBlocking(
        executable: URL,
        arguments: [String],
        input: Data = Data(),
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("taskbar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let errorFile = scratch.appendingPathComponent("stderr")
        fileManager.createFile(atPath: errorFile.path, contents: nil)

        // With no input the child reads an empty device, so it never waits on a pipe.
        let standardInput: Any
        if input.isEmpty {
            standardInput = FileHandle.nullDevice
        } else {
            let inputFile = scratch.appendingPathComponent("stdin")
            try input.write(to: inputFile)
            standardInput = try FileHandle(forReadingFrom: inputFile)
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = standardInput
        process.standardOutput = outputPipe
        process.standardError = try FileHandle(forWritingTo: errorFile)

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let startedAt = Date()
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // Only the watchdog's SIGTERM ends a command with a signal, and only after the timeout.
        let timedOut = process.terminationReason == .uncaughtSignal
            && Date().timeIntervalSince(startedAt) >= timeout
        return ProcessOutput(
            status: process.terminationStatus,
            standardOutput: output,
            standardError: (try? Data(contentsOf: errorFile)) ?? Data(),
            timedOut: timedOut
        )
    }
}
