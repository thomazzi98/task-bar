import Foundation

/// Checks a proposed action against the machine as it is at the moment the user confirms.
///
/// A proposal names a process or container from an earlier snapshot. Process IDs are reused and
/// names can change, so the live target must still match the name the user was shown.
public enum AssistantActionGuard {
    public enum Refusal: Equatable, Sendable {
        case noLongerRunning
        case protectedProcess
        case nameChanged(current: String)
    }

    /// Why the signal must not be sent, or `nil` when it may be. `live` is what the system reports
    /// for the process ID right now: its name and owner, or `nil` when no such process exists.
    public static func processRefusal(
        proposedName: String,
        pid: Int32,
        live: (name: String, userID: UInt32)?,
        currentUserID: UInt32,
        ownPID: Int32
    ) -> Refusal? {
        guard let live else { return .noLongerRunning }
        if ProcessMath.isProtected(
            pid: pid,
            userID: live.userID,
            name: live.name,
            currentUserID: currentUserID,
            ownPID: ownPID
        ) {
            return .protectedProcess
        }
        return live.name == proposedName ? nil : .nameChanged(current: live.name)
    }

    /// The one running container the proposal means: its ID starts with the proposed ID and its
    /// name matches exactly. Anything other than exactly one match is treated as no match.
    public static func container(
        matchingID id: String,
        name: String,
        in containers: [DockerContainer]
    ) -> DockerContainer? {
        let matches = containers.filter { $0.isRunning && $0.id.hasPrefix(id) && $0.name == name }
        return matches.count == 1 ? matches[0] : nil
    }
}
