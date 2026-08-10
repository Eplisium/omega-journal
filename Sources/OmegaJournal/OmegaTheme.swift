import SwiftUI

// MARK: - Design Tokens
//
// Shared typography and geometry constants so cards, charts, and headers stay
// visually consistent across views.

enum OmegaTheme {
    // Typography
    static let titleFont = Font.system(size: 20, weight: .bold, design: .serif)
    static let headingFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let metaFont = Font.system(size: 10)
    static let captionFont = Font.system(size: 9, weight: .semibold)

    // Geometry
    static let cardRadius: CGFloat = 11
    static let controlRadius: CGFloat = 7
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 16
}
