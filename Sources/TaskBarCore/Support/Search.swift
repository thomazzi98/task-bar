import Foundation

/// A task or note matching a search query.
public struct SearchResult: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// IDs from the root task down to the match, for navigating straight to it.
        case task(path: [UUID])
        case note(id: UUID)
    }

    public var target: Target
    public var title: String
    /// Where the match lives (breadcrumb) or a snippet of the matching text.
    public var subtitle: String
    public var isDone: Bool

    public var id: String {
        switch target {
        case .task(let path): "task-\(path.last?.uuidString ?? "")"
        case .note(let id): "note-\(id.uuidString)"
        }
    }

    public init(target: Target, title: String, subtitle: String, isDone: Bool = false) {
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.isDone = isDone
    }
}

/// Case- and accent-insensitive search across every task (at any depth) and every note.
public enum Search {
    public static func run(query: String, tasks: [TaskItem], notes: [Note], limit: Int = 40) -> [SearchResult] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        var titleMatches: [SearchResult] = []
        var bodyMatches: [SearchResult] = []

        for flat in TaskTree.flatten(tasks) {
            let breadcrumb = flat.ancestorTitles.joined(separator: " › ")
            if matches(flat.item.title, terms) {
                titleMatches.append(SearchResult(
                    target: .task(path: flat.path),
                    title: flat.item.title,
                    subtitle: breadcrumb,
                    isDone: flat.item.isDone
                ))
            } else if matches(flat.item.notes, terms) {
                bodyMatches.append(SearchResult(
                    target: .task(path: flat.path),
                    title: flat.item.title,
                    subtitle: snippet(of: flat.item.notes, around: terms[0]),
                    isDone: flat.item.isDone
                ))
            }
        }

        for note in notes {
            if matches(note.displayTitle, terms) {
                titleMatches.append(SearchResult(target: .note(id: note.id), title: note.displayTitle, subtitle: note.preview))
            } else if matches(note.body, terms) {
                bodyMatches.append(SearchResult(
                    target: .note(id: note.id),
                    title: note.displayTitle,
                    subtitle: snippet(of: note.body, around: terms[0])
                ))
            }
        }

        // Matches in a title are more relevant than matches buried in body text.
        return Array((titleMatches + bodyMatches).prefix(limit))
    }

    /// Every term must appear somewhere in the text.
    static func matches(_ text: String, _ terms: [String]) -> Bool {
        terms.allSatisfy { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// A short excerpt of `text` centred on the first occurrence of `term`.
    static func snippet(of text: String, around term: String, radius: Int = 48) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let range = flattened.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flattened.prefix(radius * 2))
        }
        let start = flattened.index(range.lowerBound, offsetBy: -radius, limitedBy: flattened.startIndex)
            ?? flattened.startIndex
        let end = flattened.index(range.upperBound, offsetBy: radius, limitedBy: flattened.endIndex)
            ?? flattened.endIndex
        let prefix = start > flattened.startIndex ? "…" : ""
        let suffix = end < flattened.endIndex ? "…" : ""
        return prefix + flattened[start..<end].trimmingCharacters(in: .whitespaces) + suffix
    }
}
