import Darwin
import Foundation
import TaskBarCore

/// Carries out one action the user has confirmed in the Ask tab.
///
/// Each target is checked against the live machine first, so a proposal made from an earlier
/// snapshot cannot hit a different process or container. Only the existing, guarded paths are used:
/// the process signal helper, the Docker client and the web opener.
@MainActor
enum AskActionRunner {
    /// Runs the action and returns the one-line result shown under the button.
    static func perform(_ action: ProposedAction, docker: DockerClient) async -> String {
        switch action {
        case .quit(let pid, let name):
            return signal(SIGTERM, label: "quit", name: name, pid: pid)
        case .forceQuit(let pid, let name):
            return signal(SIGKILL, label: "force quit", name: name, pid: pid)
        case .stopContainer(let id, let name):
            return await stopContainer(id: id, name: name, docker: docker)
        case .openURL(let url):
            guard ProposedAction.isWebURL(url) else { return "Not opened: only web addresses can be opened." }
            Opener.open(url)
            return "Opened \(url.absoluteString)."
        }
    }

    private static func signal(_ signal: Int32, label: String, name: String, pid: Int32) -> String {
        let live = ProcessInspector.details(of: pid).map { details in
            (name: ProcessInspector.fullName(of: pid) ?? details.name, userID: details.userID)
        }
        let refusal = AssistantActionGuard.processRefusal(
            proposedName: name,
            pid: pid,
            live: live,
            currentUserID: getuid(),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
        switch refusal {
        case .noLongerRunning?:
            return "\(name) (PID \(pid)) is no longer running. Nothing was sent."
        case .protectedProcess?:
            return "\(name) is a protected process, so it was not touched."
        case .nameChanged(let current)?:
            return "PID \(pid) is now \(current), not \(name). Nothing was sent."
        case nil:
            break
        }

        guard ProcessInspector.send(signal: signal, to: pid) else {
            return "Could not send \(label) to \(name) (PID \(pid))."
        }
        return "Sent \(label) to \(name) (PID \(pid))."
    }

    private static func stopContainer(id: String, name: String, docker: DockerClient) async -> String {
        do {
            let running = try await docker.containers(includeStopped: false)
            guard let target = AssistantActionGuard.container(matchingID: id, name: name, in: running) else {
                return "\(name) is not running any more. Nothing was stopped."
            }
            try await docker.perform(.stop, on: target.id)
            return "Stopped container \(name)."
        } catch {
            return "Could not stop \(name): \(error.localizedDescription)"
        }
    }
}
