# AGENTS.md

macOS 14+ SwiftUI journal app. Swift package, **zero third-party dependencies** — system SQLite3 C API directly, SwiftUI, LocalAuthentication.

## Language and concurrency (Swift 6)

- `swift-tools-version: 6.2`, Swift 6 language mode: data races are compile errors. Needs Xcode 26+ / Swift 6.2+.
- The app and test targets default to **main-actor isolation** (`.defaultIsolation(MainActor.self)`) plus
  `NonisolatedNonsendingByDefault` and `InferIsolatedConformances`. `OmegaJournalCore`, `OmegaJournalShared` and
  `OmegaJournalWidgetUI` stay nonisolated pure logic.
- Anything that runs off the main thread must say so: mark pure value types, models and Keychain code
  `nonisolated` (see `JournalEntry`, `Mood`, `MASDataKeyStore`, `JournalCrypto.fetchExistingAppKey`), and use
  `@concurrent` / `Task.detached` for background work. The SQLite handle is main-actor only.
- Prefer the async system APIs (`notificationSettings()`, `requestAccess(for:)`, `center.add(_:)`) over completion
  handlers: a main-actor closure handed to a callback that fires on a background queue traps at runtime.
- `deinit` is nonisolated. State it touches must be `nonisolated(unsafe)` with a comment, or lock-guarded
  (`JournalCrypto` data-probe registry).

## Observation

- Models are `@Observable` (Observation framework), not `ObservableObject`. Views own models with `@State`
  (or `LazyState` when building a spare instance has side effects, e.g. `JournalViewModel`), receive them as plain
  properties, use `@Bindable` for `$` bindings, and `@Environment(Type.self)` for injected ones.
- Views redraw only for properties they read. Mark caches, debounce tasks, snapshots and timers
  `@ObservationIgnored`; a tracked property written during `body` loops (`writingDaysCache`).
- Observation notifies on every set, even with an equal value: guard assignments that feed the App scene
  (`QuickCapturePresence`) or expensive views with `if new != old`.
- No Combine for state: persistence of `sortOrder`/`filter` is `didSet`; lock-state changes arrive through
  `BiometricAuth.observeSessionChanges(owner:)`.

## Liquid Glass

- Glass lives in `Theme/GlassStyle.swift` (`GlassPolicy` + modifiers). Every macOS 26 API sits behind
  `#available(macOS 26.0, *)` with the previous look as the fallback; `GlassPolicyTests` assert that.
- Glass is for the floating/navigation layer (toolbars, reader/editor action groups, command palette, toasts,
  hover cards, primary buttons). Content (entry text, rows, cards, calendar grid) stays solid.

## Widget and App Intents

- `OmegaJournalWidgets` is a WidgetKit extension built by SwiftPM and wrapped into
  `Contents/PlugIns/OmegaJournalWidgets.appex` by `scripts/lib/oj-packaging.sh` (sandboxed, App Group shared with the
  app). The app publishes a privacy-safe snapshot (counts, streak, prompt, last-written date; never titles or
  bodies, nothing from hidden entries) through `WidgetSnapshotPublisher`; test mode never writes it.
- App Intents live in `Sources/OmegaJournal/Intents/`. SwiftPM does not extract intent metadata, so the packaging
  lib compiles with const-value emission and runs `appintentsmetadataprocessor` to produce `Metadata.appintents`.
  Intents that need the journal queue in `AppCommandInbox` until the launch gate has adopted the key.
- Deep links: `omegajournal://` (QA bundle ids get `omegajournal-qa-<name>://`).
- Never register or launch a build with the production bundle id for QA; use `OMEGA_JOURNAL_BUNDLE_ID=...qa-<name>`.

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
Sources/OmegaJournalCore/   Pure logic only (OmegaCore.swift, EntryGrouping.swift,
                            MarkdownPlainPreview.swift): FTS sanitizer, markdown
                            import, fuzzy match, workspace/period definitions,
                            list date sections. No AppKit, no DB.
Sources/OmegaJournal/       SwiftUI app: DatabaseManager (all SQL), JournalViewModel, views.
```

- Data flow: `DatabaseManager` → `JournalViewModel` (@MainActor, all published state) → SwiftUI views. No direct SQL from views.
- ViewModel mutations must update **every** published collection (`entries`, `archivedEntries`, `trashedEntries`, …), not just the active list — `ArchiveTrashLifecycleTests` guards this.
- **Autosave race rule (critical):** the 700ms debounced autosave (`JournalViewModel.autoSave`) holds a full pre-mutation entry snapshot. EVERY immediate mutation — pin, favorite, mood, archive, hide, plus the trash/bulk paths — must call `flushBeforeImmediateMutation()` (or cancel the debounce) FIRST, or the stale snapshot lands after the mutation and silently reverts it. `AutosaveFlushAndRoundTripTests.pendingAutosaveCannotRevertImmediateMutations` guards pin/archive/hide.
- `stopEditing()` persists the pending autosave itself before clearing `editingEntryId` — the `EditorView.onDisappear` flush runs too late (id already nil) and cannot be relied on.
- Multi-statement mutations (`saveEntry`, `hardDeleteEntry`, `renameTag`, `deleteTag`, `reconcileTagStorage`, `rebuildFTS`) run inside re-entrant `beginTransaction`/`endTransaction` blocks in `DatabaseManager`. Statement failures flag the transaction so the outermost unwind rolls back instead of committing a partial write. New multi-statement mutations must do the same.
- JSON export format v3 adds optional `isHidden` (older files still import; hidden state must round-trip — backups never unhide private entries).
- Schema migrations live as sequential `migrateToVN()` functions in `DatabaseManager.swift`, tracked in the `schema_version` table (see `DatabaseManager.currentSchemaVersion`). Migrations run against real user data — they must be idempotent. New schema change = add the next `migrateToVN()` and bump the constant.
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
  counts via `BiometricAuth.observeSessionChanges(owner:)` in `JournalViewModel.init`.

## App lifetime & notifications

- Launch gate: the window shows `LaunchGateView` first, which fetches the
  EXISTING Keychain key off the main thread (`JournalCrypto.fetchExistingAppKey`,
  load-only — it must never mint a key, because no DB probe is registered yet)
  and only then builds `ContentView`. Nothing in the gate may touch
  `DatabaseManager.shared` or `ThemeManager.shared` (ThemeManager reads the DB):
  doing so reintroduces the "app never opens" hang while macOS waits on the
  Keychain prompt.
- Quit flow: `applicationWillTerminate` posts `.quitTimeSave`; ContentView's
  `onReceive` calls `vm.flushPendingSave()` synchronously (the 700ms debounced
  autosave must land before `DatabaseManager.shared` deinits and closes the DB).
- Lock/unlock: `applicationDidResignActive` posts `.lockHiddenEntries` unless
  `BiometricAuth.shared.isAuthenticating` (the auth dialog itself resigns the
  app — don't lock mid-prompt).
- `EntryRow` (EntryListView.swift) reads selection/bulk state directly from its
  `vm` (the `@Observable` JournalViewModel) instead of receiving value copies — passed-in copies go
  stale inside LazyVStack and made bulk-select taps open entries. Keep it that
  way for any new row state.

## Conventions

- Commit messages follow `feat:` / `fix:` / `docs:` / `test:` prefixes, with a
  body explaining the root cause, not just the symptom.
- Inspecting the real database (read-only!) from a shell: the `sqlite3` CLI may
  be blocked by tooling guards — use Python instead:
  `python3 -c "import sqlite3,os; db=sqlite3.connect('file:'+os.path.expanduser('~/Library/Application Support/OmegaJournal/omega_journal.sqlite3')+'?mode=ro', uri=True); ..."`
