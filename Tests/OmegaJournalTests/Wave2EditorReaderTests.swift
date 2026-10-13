import Testing
@testable import OmegaJournalCore

/// Wave 2 Editor track: reader attachment removal is permanent, so it is
/// confirmed and never offered for trashed or locked entries.
@Suite("Wave 2 reader attachment removal")
struct Wave2EditorReaderTests {
    @Test("removal is offered only for live, unlocked entries")
    func canRemove() {
        #expect(EditorReaderAttachmentPolicy.canRemove(isTrash: false, isContentLocked: false))
        #expect(!EditorReaderAttachmentPolicy.canRemove(isTrash: true, isContentLocked: false))
        #expect(!EditorReaderAttachmentPolicy.canRemove(isTrash: false, isContentLocked: true))
        #expect(!EditorReaderAttachmentPolicy.canRemove(isTrash: true, isContentLocked: true))
    }

    @Test("confirmation names the file and says it is permanent")
    func confirmationCopy() {
        #expect(EditorReaderAttachmentPolicy.confirmationTitle(filename: "synthetic.png") == "Remove “synthetic.png”?")
        #expect(EditorReaderAttachmentPolicy.confirmationMessage.contains("can't be undone"))
        #expect(EditorReaderAttachmentPolicy.confirmButton == "Remove Attachment")
    }
}
