import Foundation
import Observation
import TaskBarCore

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
            guard period != oldValue else { return }
            loop?.restart()
        }
    }
    private(set) var report: UsageReport?

    @ObservationIgnored private let scanner: UsageScanner
    /// Set once `self` is fully built, because the loop's action publishes into `self`.
    @ObservationIgnored private var loop: VisibleRefreshLoop?

    init(paths: AppPaths) {
        scanner = UsageScanner(paths: paths)
        loop = VisibleRefreshLoop(interval: .seconds(60)) { [weak self] in
            await self?.refreshReport()
        }
    }

    /// Replaces the shown report. Used only by snapshot rendering, which never starts the scan.
    func applyPreview(_ report: UsageReport) {
        self.report = report
    }

    /// Starts or stops the scan. Called from `AppEnvironment` whenever the view's visibility
    /// could have changed.
    func setVisible(_ visible: Bool) {
        loop?.setVisible(visible)
    }

    private func refreshReport() async {
        let period = period
        let fresh = await scanner.report(for: period)
        guard !Task.isCancelled else { return }
        report = fresh
    }
}
