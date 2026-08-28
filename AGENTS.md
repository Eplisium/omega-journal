# AGENTS.md

macOS 14+ SwiftUI journal app. Swift package, **zero third-party dependencies** — system SQLite3 C API directly, SwiftUI, LocalAuthentication.

## Commands

```bash
swift build          # compile
swift test           # run all tests (Swift Testing framework, not XCTest)
swift test --filter "Archive and trash lifecycle"   # single suite
bash build_app.sh    # package "Omega Journal.app" (note the space) + regenerate icon
```

- `build_app.sh` hardcodes `PROJECT_DIR="$HOME/OmegaJournal"` — it only works when the repo is checked out at that exact path. It picks the newest binary in `.build/` by mtime and rebuilds the bundle from scratch.
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
- Schema migrations live as sequential `migrateToVN()` functions in `DatabaseManager.swift`, tracked in the `schema_version` table (currently V7). Migrations run against real user data — they must be idempotent. New schema change = add `migrateToV8()` and bump.
- Tests may `@testable import OmegaJournal` (the executable target) because the test target depends on both targets.

## Conventions

- Commit messages follow `feat:` / `fix:` / `docs:` / `test:` prefixes.
