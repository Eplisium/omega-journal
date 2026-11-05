import Foundation
import Testing
@testable import OmegaJournalCore

/// core-11: tag colour validation.
@Suite("Audit fix core: tag colours and identity")
struct AuditFixCoreTagTests {
    @Test("core-11 normalizedHex rejects full-width hex digits; every accepted colour renders")
    func fullwidthHex() {
        #expect(TagColors.normalizedHex("#ＡＢＣ１２３") == nil)
        #expect(TagColors.normalizedHex("ＡＢＣ１２３") == nil)
        #expect(TagColors.normalizedHex("#12345６") == nil)
        #expect(TagColors.rgb(hex: "#ＡＢＣ１２３") == nil)
        for raw in ["#abc123", "ABC123", " #8b5cf6 "] {
            let n = TagColors.normalizedHex(raw)
            #expect(n != nil, "\(raw)")
            #expect(n.flatMap { TagColors.rgb(hex: $0) } != nil, "\(raw)")
        }
        #expect(TagColors.normalizedHex("#abc123") == "#ABC123")
        #expect(TagColors.palette.allSatisfy { TagColors.normalizedHex($0) == $0 })
    }
}
