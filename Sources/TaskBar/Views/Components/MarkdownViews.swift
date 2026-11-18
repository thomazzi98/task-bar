import AppKit
import SwiftUI
import TaskBarCore

/// Gives SwiftUI code access to the `NSTextView` behind a `MarkdownTextEditor`.
@MainActor
final class EditorProxy {
    weak var textView: NSTextView?

    /// The caret position as a UTF-16 offset, or `nil` when the editor is not on screen.
    var insertionOffset: Int? {
        textView?.selectedRange().location
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func focusAtEnd() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }
}

/// A plain-text editor for long-form notes.
///
/// Backed by `NSTextView` rather than SwiftUI's `TextEditor` to get the caret position (for
/// dictation), system Writing Tools, undo, and control over smart-substitution features that
/// would otherwise corrupt Markdown.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var proxy: EditorProxy?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isContinuousSpellCheckingEnabled = true
        // Smart substitutions rewrite `--`, quotes and list markers, which breaks Markdown.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.string = text
        proxy?.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        proxy?.textView = textView

        if textView.string != text {
            // The text changed from outside (dictation, a rewrite): keep the caret sensible.
            let selection = textView.selectedRange()
            textView.string = text
            let length = text.utf16.count
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}

/// Renders the lightweight Markdown used in notes: headings, lists, checkboxes, quotes and
/// code, with inline bold, italic, code and clickable links.
struct MarkdownPreview: View {
    let text: String
    /// Called with the source line of a checkbox the user clicked.
    var onToggleCheckbox: ((Int) -> Void)?

    var body: some View {
        let blocks = MarkdownBlockParser.parse(text)
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if blocks.isEmpty {
                    Text("Nothing to preview yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 16 : level == 2 ? 14.5 : 13, weight: .semibold))
                .padding(.top, level <= 2 ? 5 : 2)
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
        case .bullet(let text, let indent):
            listRow(marker: "•", text: text, indent: indent)
        case .numbered(let marker, let text, let indent):
            listRow(marker: marker, text: text, indent: indent)
        case .checkbox(let text, let isChecked, let indent, let line):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    onToggleCheckbox?(line)
                } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12.5))
                        .foregroundStyle(isChecked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .disabled(onToggleCheckbox == nil)
                Text(inline(text))
                    .font(.system(size: 13))
                    .strikethrough(isChecked)
                    .foregroundStyle(isChecked ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            Text(inline(text))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 2.5)
                }
        case .code(let code):
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        case .divider:
            Divider().padding(.vertical, 3)
        }
    }

    private func listRow(marker: String, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(inline(text))
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(indent) * 14)
    }

    private func inline(_ text: String) -> AttributedString {
        InlineMarkdown.attributed(text)
    }
}

enum InlineMarkdown {
    /// Bold, italic, code and links, keeping line breaks. Falls back to the literal text when
    /// it does not parse.
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
