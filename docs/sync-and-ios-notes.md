# Sync and iOS companion — design notes (not implemented)

Status: **out of scope for Phase 3/5.** These notes capture constraints so a later effort starts from the right place.

## Principles
- Local-first stays true: the Mac app must remain fully functional offline and without any account.
- End-to-end encrypted: the server (CloudKit private DB or iCloud Drive files) only ever sees ciphertext.
- Hidden entries sync as hidden; nothing about sync may unhide them.

## Constraints discovered in the current code
- **Bodies and attachments are sealed with a per-install Keychain key** (`JournalCrypto`). A second device cannot read them. Sync needs a *shareable* data key: derive it from a user passphrase (the `PassphraseVault` PBKDF2 + AES-GCM container is the building block) or share via iCloud Keychain.
- **Titles, tags, moods, timestamps, check-in metrics and habits are plaintext metadata** (documented in Settings). A sync layer must either accept that or encrypt metadata columns too.
- **No change log.** Rows have `updated_at` but there are no tombstones for hard deletes (`hardDeleteEntry`, trash purge). Sync requires: per-row `modified_at`, a deletion tombstone table, and a stable device id.
- **Check-ins/habits** are keyed by local calendar day (`yyyy-MM-dd`) — time-zone travel can duplicate days; merge by `(day, metric_id)` last-write-wins.
- **Attachments** are individually sealed files; sync them as content-addressed blobs, not inside the DB.
- **Schema versions** are linear (`schema_version`); a device on an older schema must open the shared store read-only (already how newer-schema DBs are handled).

## Suggested approach
1. Add `modified_at` + tombstones (new migration) and a device id setting.
2. File-based sync first: each device writes append-only change files (JSON, sealed with the sync key) into an iCloud Drive folder; devices replay them. Conflicts: last-writer-wins per field, with the losing version kept in a revisions table.
3. Only then consider CloudKit (`CKSyncEngine`) for the same change model.

## iOS companion
- `OmegaJournalCore` is already UI-free (it now holds the check-in/habit/import/export/review logic and has no AppKit) — a SwiftUI iOS target can depend on it directly.
- `DatabaseManager` and views are macOS-specific today (AppKit, `NSSavePanel`). Extract the SQLite layer into a shared package target before reusing it.
- Biometrics: `LocalAuthentication` works on both; `BiometricAuth` needs only a small `#if os` split.
- Likely v1 scope: quick capture, daily check-in/habit strip, read/search, On This Day. Editor parity later.
