import SwiftUI
import AppKit

// MARK: - Markdown Text Editor
//
// SwiftUI's TextEditor gives no access to the selected range, so markdown formatting
// commands (bold, italic, link…) can't be implemented on top of it. This wraps a real
// NSTextView so we can wrap the selection, auto-continue lists, and syntax-highlight
// the markdown source as the user types.

/// Formatting operations the toolbar and ⌘-shortcuts can apply to the editor.
enum MarkdownCommand {
    case bold, italic, code, strikethrough
    case heading1, heading2, heading3
    case bulletList, numberedList, checkbox, quote
    case link, divider, codeBlock

    /// Characters placed on either side of the selection, for simple wrapping commands.
    var wrap: (String, String)? {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("*", "*")
        case .code: ("`", "`")
        case .strikethrough: ("~~", "~~")
        default: nil
        }
    }

    /// Text inserted at the start of each selected line, for block commands.
    var linePrefix: String? {
        switch self {
        case .heading1: "# "
        case .heading2: "## "
        case .heading3: "### "
        case .bulletList: "- "
        case .numberedList: "1. "
        case .checkbox: "- [ ] "
        case .quote: "> "
        default: nil
        }
    }

    var icon: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .strikethrough: "strikethrough"
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .checkbox: "checklist"
        case .quote: "text.quote"
        case .link: "link"
        case .divider: "minus"
        case .codeBlock: "curlybraces"
        }
    }

    var label: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .code: "Inline Code"
        case .strikethrough: "Strikethrough"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulletList: "Bullet List"
        case .numberedList: "Numbered List"
        case .checkbox: "Checklist"
        case .quote: "Quote"
        case .link: "Link"
        case .divider: "Divider"
        case .codeBlock: "Code Block"
        }
    }
}

/// Lets SwiftUI parents send formatting commands down into the NSTextView.
@MainActor
final class MarkdownEditorController: ObservableObject {
    fileprivate weak var textView: NSTextView?

    func apply(_ command: MarkdownCommand) {
        textView?.applyMarkdownCommand(command)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Inserts text at the caret, replacing any selection.
    func insert(_ text: String) {
        guard let tv = textView else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
    }

    var selectedText: String {
        guard let tv = textView else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var lineSpacing: CGFloat = 6
    var isTypewriterMode: Bool = false
    var isFocusMode: Bool = false
    var controller: MarkdownEditorController
    var onCommandReturn: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.string = text

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        controller.textView = textView
        context.coordinator.applyHighlighting(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = textView

        // Only touch the text storage when the model genuinely diverged, otherwise
        // every keystroke would reset the insertion point to the end.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let safeLocation = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
        }
        context.coordinator.applyHighlighting(to: textView)

        if isTypewriterMode {
            context.coordinator.centerCaret(in: textView, scrollView: scrollView)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        private var highlightScheduled = false

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            applyHighlighting(to: tv)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.command) {
                    parent.onCommandReturn?()
                    return true
                }
                return continueList(in: textView)
            }
            return false
        }

        /// Pressing Return inside a list item continues the list; on an empty item it ends it.
        private func continueList(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)

            func replaceLineWithBlank() {
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: line.count))
            }

            // Checklist
            if let match = line.range(of: #"^(\s*)- \[[ xX]\] "#, options: .regularExpression) {
                let marker = String(line[match])
                if line.trimmingCharacters(in: .whitespaces) == marker.trimmingCharacters(in: .whitespaces) {
                    replaceLineWithBlank(); return true
                }
                let indent = marker.prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n\(indent)- [ ] ", replacementRange: textView.selectedRange())
                return true
            }

            // Bullet
            if let match = line.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
                let marker = String(line[match])
                if line.trimmingCharacters(in: .whitespaces).count <= 1 {
                    replaceLineWithBlank(); return true
                }
                let indent = marker.prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n\(indent)- ", replacementRange: textView.selectedRange())
                return true
            }

            // Numbered
            if let match = line.range(of: #"^(\s*)(\d+)\. "#, options: .regularExpression) {
                let marker = String(line[match])
                let digits = marker.filter(\.isNumber)
                if line.trimmingCharacters(in: .whitespaces).count <= digits.count + 1 {
                    replaceLineWithBlank(); return true
                }
                let next = (Int(digits) ?? 1) + 1
                let indent = marker.prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n\(indent)\(next). ", replacementRange: textView.selectedRange())
                return true
            }

            // Blockquote
            if line.hasPrefix("> ") {
                if line == "> " { replaceLineWithBlank(); return true }
                textView.insertText("\n> ", replacementRange: textView.selectedRange())
                return true
            }

            return false
        }

        /// Keeps the caret vertically centred (typewriter scrolling).
        func centerCaret(in textView: NSTextView, scrollView: NSScrollView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let caret = textView.selectedRange()
            let glyphRange = layoutManager.glyphRange(forCharacterRange: caret, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let target = rect.midY - scrollView.contentView.bounds.height / 2
            let clamped = max(0, min(target, max(0, textView.bounds.height - scrollView.contentView.bounds.height)))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // MARK: Syntax highlighting

        /// Highlighting runs on the shared text storage; coalesce so fast typing stays smooth.
        func applyHighlighting(to textView: NSTextView) {
            guard !highlightScheduled else { return }
            highlightScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                self?.highlightScheduled = false
                guard let self, let textView, let storage = textView.textStorage else { return }
                self.highlight(storage)
            }
        }

        private func highlight(_ storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            let baseFont = parent.font
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.lineSpacing

            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ], range: full)

            let text = storage.string
            let ns = text as NSString

            func style(_ pattern: String, _ attrs: [NSAttributedString.Key: Any], group: Int = 0) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
                regex.enumerateMatches(in: text, range: full) { match, _, _ in
                    guard let match, group < match.numberOfRanges else { return }
                    let r = match.range(at: group)
                    if r.location != NSNotFound && NSMaxRange(r) <= ns.length {
                        storage.addAttributes(attrs, range: r)
                    }
                }
            }

            let accent = NSColor.controlAccentColor
            let muted = NSColor.secondaryLabelColor
            let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)

            // Headings — scale the font by level.
            style(#"^#\s.*$"#, [.font: NSFont.systemFont(ofSize: baseFont.pointSize + 10, weight: .bold)])
            style(#"^##\s.*$"#, [.font: NSFont.systemFont(ofSize: baseFont.pointSize + 6, weight: .bold)])
            style(#"^###\s.*$"#, [.font: NSFont.systemFont(ofSize: baseFont.pointSize + 3, weight: .semibold)])
            style(#"^#{1,6}\s"#, [.foregroundColor: accent.withAlphaComponent(0.6)])

            // Emphasis
            style(#"\*\*[^*\n]+\*\*"#, [.font: boldVariant(of: baseFont)])
            style(#"(?<!\*)\*[^*\n]+\*(?!\*)"#, [.font: italicVariant(of: baseFont)])
            style(#"~~[^~\n]+~~"#, [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: muted])

            // Code
            style(#"`[^`\n]+`"#, [.font: mono, .foregroundColor: NSColor.systemOrange])
            style(#"^```[\s\S]*?^```"#, [.font: mono, .foregroundColor: NSColor.systemOrange])

            // Structure
            style(#"^\s*[-*+]\s"#, [.foregroundColor: accent])
            style(#"^\s*\d+\.\s"#, [.foregroundColor: accent])
            style(#"^\s*- \[[ xX]\]"#, [.foregroundColor: accent, .font: boldVariant(of: baseFont)])
            style(#"^>\s.*$"#, [.foregroundColor: muted, .font: italicVariant(of: baseFont)])
            style(#"^(---|\*\*\*|___)\s*$"#, [.foregroundColor: NSColor.tertiaryLabelColor])

            // Links & tags
            style(#"\[[^\]\n]*\]\([^)\n]*\)"#, [.foregroundColor: NSColor.systemBlue])
            style(#"(?<![\w/])#[A-Za-z0-9_-]+"#, [.foregroundColor: NSColor.systemPurple])

            storage.endEditing()
        }

        private func boldVariant(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }

        private func italicVariant(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
    }
}

// MARK: - NSTextView command application

extension NSTextView {
    /// Applies a markdown formatting command to the current selection.
    func applyMarkdownCommand(_ command: MarkdownCommand) {
        let ns = string as NSString
        let selection = selectedRange()

        // Inline wrapping: **bold**, *italic*, `code`, ~~strike~~
        if let (open, close) = command.wrap {
            let selected = ns.substring(with: selection)
            // Toggle off when the selection is already wrapped.
            if selected.hasPrefix(open) && selected.hasSuffix(close) && selected.count >= open.count + close.count {
                let inner = String(selected.dropFirst(open.count).dropLast(close.count))
                replaceAndSelect(inner, in: selection, selectLength: (inner as NSString).length)
            } else {
                let wrapped = open + selected + close
                let caretOffset = selection.length == 0 ? (open as NSString).length : (wrapped as NSString).length
                replaceAndSelect(wrapped, in: selection,
                                 selectLength: selection.length == 0 ? 0 : (selected as NSString).length,
                                 caretOverride: selection.length == 0 ? selection.location + caretOffset : nil)
            }
            didChangeText()
            return
        }

        // Line prefixes: headings, lists, quotes
        if let prefix = command.linePrefix {
            let lineRange = ns.lineRange(for: selection)
            let block = ns.substring(with: lineRange)
            let hadTrailingNewline = block.hasSuffix("\n")
            var lines = block.components(separatedBy: "\n")
            if hadTrailingNewline { lines.removeLast() }

            // Toggle off if every line already carries the prefix.
            let allPrefixed = lines.allSatisfy { $0.hasPrefix(prefix) }
            lines = lines.map { line in
                if allPrefixed { return String(line.dropFirst(prefix.count)) }
                // Strip a competing block marker before applying the new one.
                let stripped = line.replacingOccurrences(
                    of: #"^(#{1,6}\s|[-*+]\s(\[[ xX]\]\s)?|\d+\.\s|>\s)"#,
                    with: "", options: .regularExpression
                )
                return prefix + stripped
            }
            var replacement = lines.joined(separator: "\n")
            if hadTrailingNewline { replacement += "\n" }
            replaceAndSelect(replacement, in: lineRange, selectLength: (replacement as NSString).length)
            didChangeText()
            return
        }

        switch command {
        case .link:
            let selected = ns.substring(with: selection)
            let label = selected.isEmpty ? "text" : selected
            let replacement = "[\(label)](url)"
            // Put the caret on "url" so the user can type straight over it.
            let urlOffset = selection.location + (("[\(label)](" ) as NSString).length
            replaceAndSelect(replacement, in: selection, selectLength: 0)
            setSelectedRange(NSRange(location: urlOffset, length: 3))

        case .divider:
            insertBlock("\n---\n")

        case .codeBlock:
            let selected = ns.substring(with: selection)
            let replacement = "```\n\(selected)\n```"
            replaceAndSelect(replacement, in: selection, selectLength: 0)
            // Caret lands just after the opening fence.
            setSelectedRange(NSRange(location: selection.location + 4, length: (selected as NSString).length))

        default:
            break
        }
        didChangeText()
    }

    private func insertBlock(_ text: String) {
        insertText(text, replacementRange: selectedRange())
    }

    private func replaceAndSelect(_ replacement: String, in range: NSRange, selectLength: Int, caretOverride: Int? = nil) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        if let caret = caretOverride {
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location, length: selectLength))
        }
    }
}
