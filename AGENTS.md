# AGENTS.md

macOS 14+ SwiftUI journal app. Swift package, **zero third-party dependencies** — system SQLite3 C API directly, SwiftUI, LocalAuthentication.

## Commands

```bash
swift build          # compile
swift test           # run all tests (Swift Testing framework, not XCTest)
swift test --filter "Archive and trash lifecycle"   # single suite by name
swift test --filter "TagStorageReconciliationTests" # …or by suite struct name
bash build_app.sh    # package "Omega Journal.app" (note the space) + regenerate icon
```

Suites: "Archive and trash lifecycle", "Autosave flush and export round-trip", "Hidden entry tag participation", "Tag storage reconciliation", "Workspace presentation", plus OmegaCore unit suites. Tests that touch the DB must clean up after themselves ("Keep the shared singleton database empty for the other suites") and DB suites use `.serialized`.

- `build_app.sh` resolves the project directory from its own location, so the repo works at any checkout path (fixed in issue #1). It picks the newest binary in `.build/` by mtime and rebuilds the bundle from scratch.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`, `arguments:` parameterization) — do not add XCTest.

## Test isolation (critical)

`DatabaseManager` defaults to the user's **real journal** at `~/Library/Application Support/OmegaJournal/omega_journal.sqlite3` (WAL mode). Any test that constructs `JournalViewModel()` or `DatabaseManager()` must first point env vars at temp dirs (see `Tests/OmegaJournalTests/ArchiveTrashLifecycleTests.swift`):

```swift
setenv("OMEGA_JOURNAL_TEST_DATABASE_PATH", dbPath, 1)
setenv("OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH", attachmentsPath, 1)
```

These env vars are process-global; use a unique `UUID`-suffixed temp directory per test.

## Architecture

```
Sources/OmegaJournalCore/   Pure logic only (OmegaCore.swift): FTS sanitizer, markdown
                            import, fuzzy match, workspace/period definitions. No AppKit, no DB.
Sources/OmegaJournal/       SwiftUI app: DatabaseManager (all SQL), JournalViewModel, views.
```

- Data flow: `DatabaseManager` → `JournalViewModel` (@MainActor, all published state) → SwiftUI views. No direct SQL from views.
- ViewModel mutations must update **every** published collection (`entries`, `archivedEntries`, `trashedEntries`, …), not just the active list — `ArchiveTrashLifecycleTests` guards this.
- **Autosave race rule (critical):** the 700ms debounced autosave (`JournalViewModel.autoSave`) holds a full pre-mutation entry snapshot. EVERY immediate mutation — pin, favorite, mood, archive, hide, plus the trash/bulk paths — must call `flushBeforeImmediateMutation()` (or cancel the debounce) FIRST, or the stale snapshot lands after the mutation and silently reverts it. `AutosaveFlushAndRoundTripTests.pendingAutosaveCannotRevertImmediateMutations` guards pin/archive/hide.
- `stopEditing()` persists the pending autosave itself before clearing `editingEntryId` — the `EditorView.onDisappear` flush runs too late (id already nil) and cannot be relied on.
- Multi-statement mutations (`saveEntry`, `hardDeleteEntry`, `renameTag`, `deleteTag`, `reconcileTagStorage`, `rebuildFTS`) run inside re-entrant `beginTransaction`/`endTransaction` blocks in `DatabaseManager`. Statement failures flag the transaction so the outermost unwind rolls back instead of committing a partial write. New multi-statement mutations must do the same.
- JSON export format v3 adds optional `isHidden` (older files still import; hidden state must round-trip — backups never unhide private entries).
- Schema migrations live as sequential `migrateToVN()` functions in `DatabaseManager.swift`, tracked in the `schema_version` table (currently V7). Migrations run against real user data — they must be idempotent. New schema change = add `migrateToV8()` and bump.
- Tests may `@testable import OmegaJournal` (the executable target) because the test target depends on both targets.

## Tag storage (dual store — handle with care)

Tags live in TWO places that must mirror each other:

1. `entries.tags` — legacy comma-separated text column
2. `tags` + `entry_tags` junction tables — **the sidebar's source of truth**

`DatabaseManager.reconcileTagStorage()` runs at every launch and heals drift by
UNIONing both stores per entry, restoring the missing side, pruning orphaned
tag rows, and rebuilding FTS. It exists because historical write paths (the V2
backfill) used `execParameterized`, which **silently swallows SQL failures** —
that's how real journals developed entries with text-column-only tags that
counted as 0 in the sidebar until edited.

Rules:
- Never write one store without the other. Route tag changes through
  `saveEntry` (syncs both) or `syncTagsForEntry`.
- The two stores use different separators (text column: comma; junction concat
  in reconcile: U+1F control char) so tag names containing commas survive.
  Comma is still the text-column separator, so tag input must strip commas
  (`EditorView.commitTag`, `JournalViewModel.bulkAddTag`).
- Sidebar/filter tag counts are session-aware: `tagsWithCounts(includeHidden:)`
  excludes hidden entries' tags while the biometric session is locked. Every
  VM refresh goes through `JournalViewModel.refreshTagCounts()` — do not call
  `db.tagsWithCounts()` directly from mutation paths. Lock/unlock re-derives
  counts via a Combine subscription in `JournalViewModel.init`.

## App lifetime & notifications

- Quit flow: `applicationWillTerminate` posts `.quitTimeSave`; ContentView's
  `onReceive` calls `vm.flushPendingSave()` synchronously (the 700ms debounced
  autosave must land before `DatabaseManager.shared` deinits and closes the DB).
- Lock/unlock: `applicationDidResignActive` posts `.lockHiddenEntries` unless
  `BiometricAuth.shared.isAuthenticating` (the auth dialog itself resigns the
  app — don't lock mid-prompt).
- `EntryRow` (EntryListView.swift) reads selection/bulk state directly from its
  `@ObservedObject vm` instead of receiving value copies — passed-in copies go
  stale inside LazyVStack and made bulk-select taps open entries. Keep it that
  way for any new row state.

## Conventions

- Commit messages follow `feat:` / `fix:` / `docs:` / `test:` prefixes, with a
  body explaining the root cause, not just the symptom.
- Inspecting the real database (read-only!) from a shell: the `sqlite3` CLI may
  be blocked by tooling guards — use Python instead:
  `python3 -c "import sqlite3,os; db=sqlite3.connect('file:'+os.path.expanduser('~/Library/Application Support/OmegaJournal/omega_journal.sqlite3')+'?mode=ro', uri=True); ..."`
