import SwiftUI
import AppKit
import OmegaJournalCore

/// Inline image for a `![](omega-attachment://file#w=N)` line: decoded through the capped,
/// cached `AttachmentPreview` path, never the full-size photo.
struct InlineAttachmentImage: View {
    let attachment: Attachment?
    let alt: String
    let requestedWidth: Int?
    let db: DatabaseManager
    /// Absolute source line in the entry body; nil disables resizing.
    var onResize: ((Int?) -> Void)?
    @ObservedObject private var theme = ThemeManager.shared
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                GeometryReader { geo in
                    let natural = Double(image.size.width)
                    let w = ImageRefs.displayWidth(requested: requestedWidth, natural: natural, available: Double(geo.size.width))
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: CGFloat(w))
                        .clipShape(RoundedRectangle(cornerRadius: OmegaTheme.Radius.control, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { resizeMenu }
                        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
                }
                .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                .frame(maxWidth: CGFloat(max(requestedWidth ?? 100_000, 40)), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text(attachment == nil ? "Image not attached" : "Image unavailable")
                }
                .font(OmegaTheme.font(.meta))
                .foregroundColor(theme.secondaryTextColor)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: OmegaTheme.Radius.chip).fill(theme.cardColor.opacity(0.5)))
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var resizeMenu: some View {
        if let onResize {
            Button("Small") { onResize(ImageRefs.presetWidths[0]) }
            Button("Medium") { onResize(ImageRefs.presetWidths[1]) }
            Button("Large") { onResize(ImageRefs.presetWidths[2]) }
            Button("Original size") { onResize(nil) }
        }
    }

    private func load() {
        guard image == nil, let attachment else { return }
        let key = "inline-" + attachment.id
        if let hit = AttachmentPreview.cached(key) { image = hit; return }
        guard let data = db.readAttachmentData(attachment),
              let img = AttachmentPreview.thumbnail(from: data, maxPixel: 1600) else { return }
        AttachmentPreview.store(img, for: key)
        image = img
    }
}
