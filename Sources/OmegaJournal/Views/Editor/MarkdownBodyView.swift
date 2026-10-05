import SwiftUI
import OmegaJournalCore

/// Renders markdown with tables as a real grid and `![](omega-attachment://…)` lines as inline
/// images; everything else as selectable text.
struct MarkdownBodyView: View {
    let markdown: String
    var style: MarkdownRenderStyle = .default
    var textColor: Color = .primary
    var lineSpacing: CGFloat = 5
    /// Attachments of the entry, so inline image references can resolve. Empty = images show as placeholders.
    var attachments: [Attachment] = []
    var db: DatabaseManager? = nil
    /// (source line, new width) — nil disables the resize menu (e.g. trash).
    var onResizeImage: ((Int, Int?) -> Void)? = nil

    private enum Piece: Identifiable {
        case markdown(line: Int, text: String)
        case image(line: Int, MarkdownImageRef)
        var id: Int { switch self { case .markdown(let l, _): l * 2; case .image(let l, _): l * 2 + 1 } }
    }

    /// Splits at standalone image lines (outside code fences). Text slices keep absolute line numbers.
    private func pieces() -> [Piece] {
        guard markdown.contains(ImageRefs.scheme + "://") else { return [.markdown(line: 0, text: markdown)] }
        let lines = markdown.components(separatedBy: "\n")
        var imageLines: [Int: MarkdownImageRef] = [:]
        for item in MarkdownLogic.parseBlocks(markdown) {
            if case let .paragraph(text) = item.block, let ref = ImageRefs.standaloneRef(inLine: text) {
                imageLines[item.line] = ref
            }
        }
        guard !imageLines.isEmpty else { return [.markdown(line: 0, text: markdown)] }
        var out: [Piece] = []
        var start = 0
        for line in imageLines.keys.sorted() {
            if line > start { out.append(.markdown(line: start, text: lines[start..<line].joined(separator: "\n"))) }
            out.append(.image(line: line, imageLines[line]!))
            start = line + 1
        }
        if start < lines.count { out.append(.markdown(line: start, text: lines[start...].joined(separator: "\n"))) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(pieces()) { piece in
                switch piece {
                case let .markdown(line, text):
                    segmentsView(MarkdownRenderer.renderSegments(text, style: style, lineOffset: line))
                case let .image(line, ref):
                    if let db {
                        InlineAttachmentImage(
                            attachment: attachments.first { $0.filename == ref.filename && $0.isImage },
                            alt: ref.alt, requestedWidth: ref.width, db: db,
                            onResize: onResizeImage.map { cb in { width in cb(line, width) } })
                    } else {
                        Text(ref.alt.isEmpty ? "[image: \(ref.filename)]" : "[image: \(ref.alt)]")
                            .foregroundColor(style.mutedColor)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentsView(_ segments: [MarkdownRenderer.Segment]) -> some View {
        ForEach(segments) { segment in
            switch segment {
            case .text(_, let attr):
                Text(attr)
                    .foregroundColor(textColor)
                    .lineSpacing(lineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .table(_, let header, let alignments, let rows):
                table(header: header, alignments: alignments, rows: rows)
            }
        }
    }

    private func alignment(_ a: MarkdownBlockItem.Alignment) -> HorizontalAlignment {
        switch a { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }

    private func table(header: [AttributedString], alignments: [MarkdownBlockItem.Alignment],
                       rows: [[AttributedString]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { i in cell(header[i], alignments[i], header: true) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c], alignments[c], header: false) }
                    }
                    .background(r % 2 == 1 ? style.mutedColor.opacity(0.06) : Color.clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style.mutedColor.opacity(0.3), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func cell(_ text: AttributedString, _ align: MarkdownBlockItem.Alignment, header: Bool) -> some View {
        Text(text)
            .foregroundColor(textColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(align), vertical: .center))
            .background(header ? style.mutedColor.opacity(0.12) : Color.clear)
            .gridColumnAlignment(alignment(align))
    }
}
