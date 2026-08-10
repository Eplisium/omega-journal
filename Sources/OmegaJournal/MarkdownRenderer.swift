import Foundation
import SwiftUI

// MARK: - Markdown Renderer
// Simple markdown → AttributedString parser for journal entries.
// Supports: headers (#), bold (**), italic (*), code (`), links, lists, blockquotes

enum MarkdownRenderer {
    static func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        let lines = markdown.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            if i > 0 {
                result += AttributedString("\n")
            }
            result += renderLine(line)
        }
        return result
    }

    private static func renderLine(_ line: String) -> AttributedString {
        // Headers
        if line.hasPrefix("### ") {
            return renderStyled(String(line.dropFirst(4)), size: 16, weight: .semibold)
        }
        if line.hasPrefix("## ") {
            return renderStyled(String(line.dropFirst(3)), size: 20, weight: .bold)
        }
        if line.hasPrefix("# ") {
            return renderStyled(String(line.dropFirst(2)), size: 24, weight: .bold)
        }

        // Blockquote
        if line.hasPrefix("> ") {
            var attr = renderInline(String(line.dropFirst(2)))
            attr.foregroundColor = .secondary
            attr.font = .system(size: 15, design: .serif).italic()
            return attr
        }

        // Unordered list
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            var attr = AttributedString("  \u{2022}  ")
            attr.foregroundColor = .secondary
            attr += renderInline(String(line.dropFirst(2)))
            return attr
        }

        // Ordered list (simple detection)
        if let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let num = String(line[range])
            let text = String(line[range.upperBound...])
            var attr = AttributedString("  \(num)")
            attr.foregroundColor = .secondary
            attr += renderInline(text)
            return attr
        }

        // Horizontal rule
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
            var attr = AttributedString("\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}")
            attr.foregroundColor = .secondary.opacity(0.4)
            return attr
        }

        return renderInline(line)
    }

    private static func renderInline(_ text: String) -> AttributedString {
        // Use a simple state machine instead of regex to avoid */** ambiguity
        var result = AttributedString()
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            // Bold: **text**
            if i + 1 < chars.count && chars[i] == "*" && chars[i + 1] == "*" {
                if let end = findClosing(from: i + 2, in: chars, marker: "**") {
                    let boldText = String(chars[(i + 2)..<end])
                    var bold = AttributedString(boldText)
                    bold.font = .system(size: 16, weight: .bold, design: .serif)
                    result += bold
                    i = end + 2
                    continue
                }
            }

            // Italic: *text*
            if chars[i] == "*" {
                if let end = findClosing(from: i + 1, in: chars, marker: "*") {
                    let italicText = String(chars[(i + 1)..<end])
                    var italic = AttributedString(italicText)
                    italic.font = .system(size: 16, design: .serif).italic()
                    result += italic
                    i = end + 1
                    continue
                }
            }

            // Inline code: `text`
            if chars[i] == "`" {
                if let end = findClosing(from: i + 1, in: chars, marker: "`") {
                    let codeText = String(chars[(i + 1)..<end])
                    var code = AttributedString(codeText)
                    code.font = .system(size: 14, design: .monospaced)
                    code.foregroundColor = .orange
                    code.backgroundColor = Color.orange.opacity(0.1)
                    result += code
                    i = end + 1
                    continue
                }
            }

            // Link: [text](url)
            if chars[i] == "[" {
                if let closeBracket = findChar(from: i + 1, in: chars, char: "]"),
                   closeBracket + 1 < chars.count && chars[closeBracket + 1] == "(",
                   let closeParen = findChar(from: closeBracket + 2, in: chars, char: ")") {
                    let linkText = String(chars[(i + 1)..<closeBracket])
                    let urlStr = String(chars[(closeBracket + 2)..<closeParen])
                    var link = AttributedString(linkText)
                    link.link = URL(string: urlStr)
                    link.foregroundColor = .blue
                    link.underlineStyle = .single
                    result += link
                    i = closeParen + 1
                    continue
                }
            }

            // Plain character
            var plain = AttributedString(String(chars[i]))
            plain.font = .system(size: 16, design: .serif)
            result += plain
            i += 1
        }

        return result
    }

    private static func findClosing(from start: Int, in chars: [Character], marker: String) -> Int? {
        let markerChars = Array(marker)
        for i in start..<chars.count {
            var match = true
            for (j, mc) in markerChars.enumerated() {
                if i + j >= chars.count || chars[i + j] != mc {
                    match = false
                    break
                }
            }
            if match { return i }
        }
        return nil
    }

    private static func findChar(from start: Int, in chars: [Character], char: Character) -> Int? {
        for i in start..<chars.count {
            if chars[i] == char { return i }
        }
        return nil
    }

    private static func renderStyled(_ text: String, size: CGFloat, weight: Font.Weight) -> AttributedString {
        var attr = renderInline(text)
        attr.font = .system(size: size, weight: weight, design: .serif)
        return attr
    }
}
