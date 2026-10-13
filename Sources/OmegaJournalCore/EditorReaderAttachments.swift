import Foundation

/// Editor track (wave 2): rules for removing an attachment from the reader.
/// Removing deletes the encrypted file and its row immediately (version
/// history does not keep attachments), so it is confirmed first, and it is
/// never offered for a trashed entry (read-only until restored) or while a
/// hidden entry is locked.
public enum EditorReaderAttachmentPolicy {
    public static func canRemove(isTrash: Bool, isContentLocked: Bool) -> Bool {
        !isTrash && !isContentLocked
    }

    public static func confirmationTitle(filename: String) -> String {
        "Remove “\(filename)”?"
    }

    public static let confirmationMessage =
        "The file is permanently deleted from this entry. This can't be undone."

    public static let confirmButton = "Remove Attachment"
}
