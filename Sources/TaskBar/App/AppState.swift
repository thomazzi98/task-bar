import Foundation
import Observation

/// The sections of the popover.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case tasks, notes, agents, calendar, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .notes: "Notes"
        case .agents: "Agents"
        case .calendar: "Calendar"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .tasks: "checklist"
        case .notes: "note.text"
        case .agents: "sparkles"
        case .calendar: "calendar"
        case .system: "gauge.with.dots.needle.50percent"
        }
    }
}

/// What the menu bar icon should signal.
enum BadgeState: Equatable, Sendable {
    case none
    /// Agents blocked on the user.
    case attention(Int)
    /// Agents that finished a turn nobody has looked at.
    case finished(Int)
}

/// Transient UI state shared across the popover.
@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .tasks
    var isPinned = false
    var isSearching = false
    var searchQuery = ""
    var isShowingSettings = false
    /// Mirrors whether the popover is on screen, so views can pause work while hidden.
    var isPanelVisible = false
    /// Incremented to ask the visible screen to focus its main text field.
    private(set) var focusRequest = 0
    /// Short confirmation shown at the bottom of the popover.
    private(set) var toast: String?

    /// While positive, the popover stays open even if it loses focus. Used around system
    /// permission prompts, which would otherwise dismiss it.
    @ObservationIgnored private(set) var holdOpenCount = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func requestPrimaryFocus() {
        focusRequest += 1
    }

    func select(_ tab: AppTab) {
        isShowingSettings = false
        isSearching = false
        selectedTab = tab
    }

    func beginSearch() {
        isShowingSettings = false
        isSearching = true
        requestPrimaryFocus()
    }

    func endSearch() {
        isSearching = false
        searchQuery = ""
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Keeps the popover open for the duration of `operation`.
    func holdingOpen<Result>(_ operation: () async -> Result) async -> Result {
        holdOpenCount += 1
        defer { holdOpenCount -= 1 }
        return await operation()
    }
}
