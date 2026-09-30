import SwiftUI
import OmegaJournalCore

/// Renders markdown with tables as a real grid; everything else as selectable text.
struct MarkdownBodyView: View {
    let markdown: String
    var style: MarkdownRenderStyle = .default
    var textColor: Color = .primary
    var lineSpacing: CGFloat = 5

    var body: some View {
        let segments = MarkdownRenderer.renderSegments(markdown, style: style)
        VStack(alignment: .leading, spacing: 10) {
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
