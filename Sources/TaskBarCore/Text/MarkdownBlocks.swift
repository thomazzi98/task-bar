import Foundation

/// A block-level element of the lightweight Markdown the notes preview understands.
/// Inline styling (bold, italic, code, links) is left to `AttributedString(markdown:)`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(text: String, indent: Int)
    case numbered(marker: String, text: String, indent: Int)
    /// `line` is the zero-based source line, so the preview can toggle the box in place.
    case checkbox(text: String, isChecked: Bool, indent: Int, line: Int)
    case quote(String)
    case code(String)
    case divider
}

public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for (lineNumber, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2

            if let block = structuredBlock(trimmed, indent: indent, line: lineNumber) {
                flushParagraph()
                blocks.append(block)
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        // An unterminated fence still renders as code rather than disappearing.
        if let lines = codeLines { blocks.append(.code(lines.joined(separator: "\n"))) }
        return blocks
    }

    /// Flips the `[ ]` / `[x]` marker on the given source line, if there is one.
    public static func togglingCheckbox(atLine line: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        let current = lines[line]
        if let range = current.range(of: "[ ]") {
            lines[line] = current.replacingCharacters(in: range, with: "[x]")
        } else if let range = current.range(of: "[x]", options: .caseInsensitive) {
            lines[line] = current.replacingCharacters(in: range, with: "[ ]")
        }
        return lines.joined(separator: "\n")
    }

    /// The text of one line without its Markdown markers, for compact previews.
    public static func plainText(ofLine line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("```"), text != "---", text != "***", text != "___" else { return "" }

        // Block markers: headings, quotes, list bullets, numbering and checkboxes.
        text = String(text.drop { $0 == "#" || $0 == ">" }).trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count))
            break
        }
        let digits = text.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = text.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { text = String(rest.dropFirst(2)) }
        }

        // Inline markers: emphasis and code. `[label](url)` keeps its label.
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Private

    private static func structuredBlock(_ line: String, indent: Int, line lineNumber: Int) -> MarkdownBlock? {
        if line == "---" || line == "***" || line == "___" { return .divider }

        if line.hasPrefix("#") {
            let level = line.prefix { $0 == "#" }.count
            let rest = line.dropFirst(level)
            if level <= 6, rest.hasPrefix(" ") {
                return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
            }
        }

        if line.hasPrefix(">") {
            return .quote(line.dropFirst().trimmingCharacters(in: .whitespaces))
        }

        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let content = String(line.dropFirst(marker.count))
            if content.hasPrefix("[ ] ") || content == "[ ]" {
                return .checkbox(text: checkboxText(content), isChecked: false, indent: indent, line: lineNumber)
            }
            if content.lowercased().hasPrefix("[x] ") || content.lowercased() == "[x]" {
                return .checkbox(text: checkboxText(content), isChecked: true, indent: indent, line: lineNumber)
            }
            return .bullet(text: content.trimmingCharacters(in: .whitespaces), indent: indent)
        }

        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .numbered(
                    marker: "\(digits).",
                    text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces),
                    indent: indent
                )
            }
        }
        return nil
    }

    private static func checkboxText(_ content: String) -> String {
        String(content.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }
}
