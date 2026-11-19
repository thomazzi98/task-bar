import Foundation
import Observation
import TaskBarCore

/// What the Agents tab shows: the live session list or Claude Code's token usage.
enum AgentsSection: String, CaseIterable, Identifiable {
    case sessions, usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .usage: "Usage"
        }
    }
}

/// Claude Code token usage, read from the transcripts on disk.
///
/// The scan runs only while the Usage section is on screen: once when it appears, then once a
/// minute. Nothing is read while the popover is closed or another tab or section is shown.
/// Each pass reads only what changed since the previous one, on `UsageScanner`'s own actor.
@MainActor
@Observable
final class UsageViewModel {
    var section: AgentsSection = .sessions
    var period: UsagePeriod = .week {
        didSet {
            guard period != oldValue, isVisible else { return }
            restartRefresh()
        }
    }
    private(set) var report: UsageReport?

    @ObservationIgnored private let scanner: UsageScanner
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false

    init(paths: AppPaths) {
        scanner = UsageScanner(paths: paths)
    }

    /// Starts or stops the scan. Called from `AppEnvironment` whenever the view's visibility
    /// could have changed.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            restartRefresh()
        } else {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func restartRefresh() {
        refreshTask?.cancel()
        let period = period
        refreshTask = Task { [weak self, scanner] in
            while !Task.isCancelled {
                let fresh = await scanner.report(for: period)
                guard !Task.isCancelled else { return }
                self?.report = fresh
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}
