import SwiftUI
import AppKit
import OmegaJournalCore

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
    /// Toggles `- [ ]` ↔ `- [x]` on the selected lines (converts bullets/plain lines to tasks).
    case toggleTask

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
        case .toggleTask: "checkmark.square"
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
        case .toggleTask: "Toggle Task Done"
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

    /// Wraps the text view's own find bar visibility so Esc can close it first.
    var isFindBarVisible: Bool {
        textView?.enclosingScrollView?.isFindBarVisible ?? false
    }

    func hideFindBar() {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.hideFindInterface.rawValue
        tv.performTextFinderAction(item)
    }

    var selectedText: String {
        guard let tv = textView else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
}

/// Theme-driven colors for source highlighting.
struct MarkdownEditorPalette: Hashable {
    var text: NSColor
    var muted: NSColor
    var accent: NSColor
    var code: NSColor
    var link: NSColor
    var tag: NSColor

    static let system = MarkdownEditorPalette(
        text: .labelColor, muted: .secondaryLabelColor, accent: .controlAccentColor,
        code: .systemOrange, link: .controlAccentColor, tag: .controlAccentColor)
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var lineSpacing: CGFloat = 6
    var isTypewriterMode: Bool = false
    var isFocusMode: Bool = false
    var controller: MarkdownEditorController
    var palette: MarkdownEditorPalette = .system
    var onCommandReturn: (() -> Void)?
    /// Esc pressed in the text view. Return true when handled (find bar / zen closed).
    var onEscape: (() -> Bool)?
    /// Number of words in the current selection (0 when nothing is selected).
    var onSelectionWords: ((Int) -> Void)?

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
        context.coordinator.applyHighlighting(to: textView, full: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = textView

        // Only touch the text storage when the model genuinely diverged (equal text
        // must never be reassigned: it resets the caret and wipes the undo stack).
        var needsFull = false
        if textView.string != text {
            let selected = textView.selectedRange()
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            // Replace through the undo-aware path so external edits stay undoable.
            if textView.shouldChangeText(in: whole, replacementString: text) {
                context.coordinator.suppressChangeCallback = true
                textView.textStorage?.replaceCharacters(in: whole, with: text)
                context.coordinator.suppressChangeCallback = false
                textView.didChangeText()
            }
            let safeLocation = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            needsFull = true
        }
        if context.coordinator.styleSignature != context.coordinator.signature(for: self) { needsFull = true }
        context.coordinator.applyHighlighting(to: textView, full: needsFull)

        if isTypewriterMode {
            context.coordinator.centerCaret(in: textView, scrollView: scrollView)
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var suppressChangeCallback = false
        private var highlightScheduled = false
        private var needsFullPass = true
        /// Union of ranges touched since the last highlight pass (post-edit coordinates).
        private var dirtyRange: NSRange?
        private var lastCodeRanges: [NSRange] = []
        var styleSignature = ""

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func signature(for editor: MarkdownTextEditor) -> String {
            "\(editor.font.fontName)|\(editor.font.pointSize)|\(editor.lineSpacing)|\(editor.palette.hashValue)"
        }

        // MARK: Delegate

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Smart paste / auto-pairing. Skipped while an IME composition is in progress.
            if !textView.hasMarkedText(), let typed = replacementString {
                let sel = textView.selectedRange()
                if typed.count > 1, affectedCharRange == sel, sel.length > 0,
                   NSPasteboard.general.string(forType: .string) == typed,
                   let link = MarkdownLogic.pasteLink(selected: (textView.string as NSString).substring(with: sel), pasted: typed) {
                    textView.insertText(link, replacementRange: sel)
                    return false
                }
                if typed.count == 1, let ch = typed.first, affectedCharRange == sel,
                   let edit = MarkdownLogic.autoPairEdit(typed: ch, in: textView.string, selection: sel) {
                    if edit.replacement.isEmpty {
                        textView.setSelectedRange(edit.selection)
                    } else {
                        textView.insertText(edit.replacement, replacementRange: edit.range)
                        textView.setSelectedRange(edit.selection)
                    }
                    return false
                }
            }
            let newRange = NSRange(location: affectedCharRange.location, length: (replacementString as NSString?)?.length ?? 0)
            if let d = dirtyRange { dirtyRange = NSUnionRange(d, newRange) } else { dirtyRange = newRange }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if !suppressChangeCallback, parent.text != tv.string { parent.text = tv.string }
            applyHighlighting(to: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let cb = parent.onSelectionWords else { return }
            let r = tv.selectedRange()
            let words = r.length == 0 ? 0 : MarkdownLogic.wordCount((tv.string as NSString).substring(with: r))
            DispatchQueue.main.async { cb(words) }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.command) {
                    parent.onCommandReturn?()
                    return true
                }
                return continueList(in: textView)
            case #selector(NSResponder.insertTab(_:)):
                return shiftLines(in: textView, outdenting: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return shiftLines(in: textView, outdenting: true)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape?() ?? false
            default:
                return false
            }
        }

        // MARK: Tab / Shift-Tab

        /// Tab indents list items (or any multi-line selection); Shift-Tab outdents.
        /// Returns false to let a plain Tab insert a tab character in ordinary prose.
        private func shiftLines(in textView: NSTextView, outdenting: Bool) -> Bool {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let lineRange = ns.lineRange(for: sel)
            let block = ns.substring(with: lineRange)
            let multiLine = block.trimmingCharacters(in: .newlines).contains("\n")
            let firstLine = block.components(separatedBy: "\n").first ?? ""
            guard multiLine || MarkdownLogic.isListLine(firstLine) || outdenting else { return false }

            let shifted = MarkdownLogic.shiftBlock(block, outdenting: outdenting)
            if shifted == block { return outdenting }   // swallow Shift-Tab even when nothing to remove
            guard textView.shouldChangeText(in: lineRange, replacementString: shifted) else { return true }
            textView.textStorage?.replaceCharacters(in: lineRange, with: shifted)
            let delta = (shifted as NSString).length - lineRange.length
            if multiLine || sel.length > 0 {
                textView.setSelectedRange(NSRange(location: lineRange.location, length: (shifted as NSString).length - (block.hasSuffix("\n") ? 1 : 0)))
            } else {
                textView.setSelectedRange(NSRange(location: max(lineRange.location, sel.location + delta), length: 0))
            }
            textView.didChangeText()
            return true
        }

        // MARK: List continuation

        /// Pressing Return inside a list item continues the list; on an empty item it ends
        /// (or outdents) it. All offsets are UTF-16.
        private func continueList(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let sel = textView.selectedRange()
            let caret = min(sel.location, ns.length)
            let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
            var contentRange = lineRange
            while contentRange.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(contentRange) - 1)) {
                contentRange.length -= 1
            }
            let line = ns.substring(with: contentRange)
            guard let ctx = MarkdownLogic.listContext(forLine: line) else { return false }
            // Caret inside the marker: behave like a normal newline.
            if caret - lineRange.location < ctx.markerLength && !ctx.isEmptyItem { return false }

            if ctx.isEmptyItem && sel.length == 0 {
                // Only when the caret is at the end of the (empty) item.
                guard caret >= NSMaxRange(contentRange) || caret - lineRange.location >= ctx.markerLength else { return false }
                if textView.shouldChangeText(in: contentRange, replacementString: ctx.exitLine) {
                    textView.textStorage?.replaceCharacters(in: contentRange, with: ctx.exitLine)
                    textView.setSelectedRange(NSRange(location: contentRange.location + (ctx.exitLine as NSString).length, length: 0))
                    textView.didChangeText()
                }
                return true
            }

            textView.insertText("\n" + ctx.nextPrefix, replacementRange: sel)

            // Ordered lists: renumber following siblings so inserting mid-list stays consistent.
            if ctx.orderedNumber != nil {
                let text = textView.string
                let newLine = MarkdownLogic.lineIndex(ofUTF16Offset: textView.selectedRange().location, in: text)
                if let edit = MarkdownLogic.renumberEdit(in: text, fromLine: newLine) {
                    let keep = textView.selectedRange()
                    if textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                        textView.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
                        textView.setSelectedRange(keep)
                        textView.didChangeText()
                    }
                }
            }
            return true
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
        /// Only the edited paragraph(s) are restyled unless `full` is requested, or a code
        /// fence appeared/disappeared (which changes styling further down the document).
        func applyHighlighting(to textView: NSTextView, full: Bool = false) {
            if full { needsFullPass = true }
            guard !highlightScheduled else { return }
            highlightScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.highlightScheduled = false
                guard let textView, let storage = textView.textStorage else { return }
                self.runHighlight(storage)
            }
        }

        private func runHighlight(_ storage: NSTextStorage) {
            let ns = storage.string as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let codeRanges = MarkdownLogic.codeBlockRanges(in: storage.string)
            if codeRanges != lastCodeRanges { needsFullPass = true }
            lastCodeRanges = codeRanges

            var target = fullRange
            if !needsFullPass, let dirty = dirtyRange, NSMaxRange(dirty) <= ns.length, dirty.length < 20_000 {
                target = ns.lineRange(for: dirty)
            } else if !needsFullPass, dirtyRange == nil {
                return
            }
            needsFullPass = false
            dirtyRange = nil
            styleSignature = signature(for: parent)
            highlight(storage, in: target, codeRanges: codeRanges)
        }

        private func highlight(_ storage: NSTextStorage, in range: NSRange, codeRanges: [NSRange]) {
            let baseFont = parent.font
            let pal = parent.palette
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.lineSpacing

            let text = storage.string
            let ns = text as NSString
            let mono = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)

            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: pal.text,
                .paragraphStyle: paragraph,
            ], range: range)

            // Code blocks: mono, no other styling inside.
            for cr in codeRanges {
                let inter = NSIntersectionRange(cr, range)
                if inter.length > 0 {
                    storage.addAttributes([.font: mono, .foregroundColor: pal.code], range: inter)
                }
            }

            func inCode(_ r: NSRange) -> Bool {
                codeRanges.contains { NSIntersectionRange($0, r).length > 0 }
            }

            func style(_ pattern: String, _ attrs: [NSAttributedString.Key: Any], group: Int = 0) {
                guard let regex = Self.regex(pattern) else { return }
                regex.enumerateMatches(in: text, range: range) { match, _, _ in
                    guard let match, group < match.numberOfRanges else { return }
                    let r = match.range(at: group)
                    if r.location != NSNotFound && NSMaxRange(r) <= ns.length && !inCode(r) {
                        storage.addAttributes(attrs, range: r)
                    }
                }
            }

            // Headings — scale the font by level (most specific last so it wins).
            style(#"^#\s.*$"#, [.font: NSFont.systemFont(ofSize: baseFont.pointSize + 10, weight: .bold)])
            style(#"^##\s.*$"#, [.font: NSFont.systemFont(ofSize: baseFont.pointSize + 6, weight: .bold)])
            style(#"^###\s.*$"#, [.font: NSFont.systemFont(ofSize: baseFont.pointSize + 3, weight: .semibold)])
            style(#"^#{1,6}\s"#, [.foregroundColor: pal.accent.withAlphaComponent(0.6)])

            // Emphasis
            style(#"\*\*[^*\n]+\*\*"#, [.font: boldVariant(of: baseFont)])
            style(#"(?<!\*)\*[^*\n]+\*(?!\*)"#, [.font: italicVariant(of: baseFont)])
            style(#"(?<![\w_])_[^_\n]+_(?![\w_])"#, [.font: italicVariant(of: baseFont)])
            style(#"~~[^~\n]+~~"#, [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: pal.muted])

            // Inline code
            style(#"`[^`\n]+`"#, [.font: mono, .foregroundColor: pal.code])

            // Structure
            style(#"^[ \t]*[-*+]\s"#, [.foregroundColor: pal.accent])
            style(#"^[ \t]*\d+[.)]\s"#, [.foregroundColor: pal.accent])
            style(#"^[ \t]*[-*+] \[[xX]\].*$"#, [.foregroundColor: pal.muted])
            style(#"^[ \t]*[-*+] \[[ xX]\]"#, [.foregroundColor: pal.accent, .font: boldVariant(of: baseFont)])
            style(#"^(?:[ \t]*>)+.*$"#, [.foregroundColor: pal.muted, .font: italicVariant(of: baseFont)])
            style(#"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#, [.foregroundColor: pal.muted.withAlphaComponent(0.6)])

            // Links & tags
            style(#"\[[^\]\n]*\]\([^)\n]*\)"#, [.foregroundColor: pal.link])
            style(#"(?<![\w/])#[A-Za-z0-9_-]+"#, [.foregroundColor: pal.tag])

            storage.endEditing()
        }

        private static var regexCache: [String: NSRegularExpression] = [:]
        private static func regex(_ pattern: String) -> NSRegularExpression? {
            if let r = regexCache[pattern] { return r }
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
            regexCache[pattern] = r
            return r
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
            let result = OmegaCore.toggleWrap(selected, open: open, close: close)
            // Unwrapping shortens the text; wrapping lengthens it.
            if result.count < selected.count {
                replaceAndSelect(result, in: selection, selectLength: (result as NSString).length)
            } else if selection.length == 0 {
                // Empty selection: drop the caret between the new markers.
                replaceAndSelect(result, in: selection, selectLength: 0,
                                 caretOverride: selection.location + (open as NSString).length)
            } else {
                replaceAndSelect(result, in: selection, selectLength: (result as NSString).length)
            }
            didChangeText()
            return
        }

        if command == .toggleTask {
            let lineRange = ns.lineRange(for: selection)
            let block = ns.substring(with: lineRange)
            let hadTrailing = block.hasSuffix("\n")
            var lines = block.components(separatedBy: "\n")
            if hadTrailing { lines.removeLast() }
            let out = lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? $0 : MarkdownLogic.cycledTaskLine($0) }
                .joined(separator: "\n") + (hadTrailing ? "\n" : "")
            replaceAndSelect(out, in: lineRange, selectLength: (out as NSString).length - (hadTrailing ? 1 : 0))
            didChangeText()
            return
        }

        // Line prefixes: headings, lists, quotes
        if let prefix = command.linePrefix {
            let lineRange = ns.lineRange(for: selection)
            let replacement = OmegaCore.applyLinePrefix(prefix, to: ns.substring(with: lineRange))
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
