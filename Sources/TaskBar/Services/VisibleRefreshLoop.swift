import Foundation

/// Runs an action while its view is on screen: at once when the view appears, then every
/// `interval`, and not at all once it is hidden. The loop owns its task, so a hidden view costs
/// nothing.
@MainActor
final class VisibleRefreshLoop {
    private let interval: Duration
    private let action: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var isVisible = false

    init(interval: Duration, action: @escaping @MainActor () async -> Void) {
        self.interval = interval
        self.action = action
    }

    /// Starts the loop when the view becomes visible and cancels it when the view is hidden.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            restart()
        } else {
            task?.cancel()
            task = nil
        }
    }

    /// Runs the action now and starts the interval again, for when its inputs changed. Does
    /// nothing while the view is hidden.
    func restart() {
        guard isVisible else { return }
        task?.cancel()
        let interval = interval
        let action = action
        task = Task(priority: .utility) {
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: interval)
            }
        }
    }
}
