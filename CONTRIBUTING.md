# Contributing to Omega Journal

Thanks for wanting to help! Omega Journal is a native, local-first journal for
macOS. It is small enough to understand in an afternoon, and every part of it —
editor, library, reflection views, storage — welcomes contributions.

**New here?** Look for issues labelled
[`good first issue`](https://github.com/Eplisium/omega-journal/labels/good%20first%20issue)
or [`help wanted`](https://github.com/Eplisium/omega-journal/labels/help%20wanted),
or say hi in [Discussions](https://github.com/Eplisium/omega-journal/discussions).
Comment on an issue before starting so nobody duplicates work.

## Getting set up (5 minutes)

Requirements: macOS 14+ and a recent Xcode / Swift toolchain (Swift 6 or newer).
There are **no third-party dependencies** — just SwiftUI, AppKit, CryptoKit and
the system SQLite C API.

```bash
git clone https://github.com/Eplisium/omega-journal.git
cd omega-journal
swift build            # compile
swift test             # run the test suite (Swift Testing)
bash build_app.sh      # package "Omega Journal.app" (note the space)
open "Omega Journal.app"
```

You can also open `Package.swift` in Xcode and run the `OmegaJournal` scheme.

### Use a throwaway journal while developing

By default the app opens your **real** journal at
`~/Library/Application Support/OmegaJournal/`. While hacking, point it at a
scratch database instead — this also uses a temporary in-memory encryption key,
so your Keychain is never touched:

```bash
mkdir -p /tmp/omega-dev
OMEGA_JOURNAL_TEST_DATABASE_PATH=/tmp/omega-dev/journal.sqlite3 \
  "Omega Journal.app/Contents/MacOS/OmegaJournal"
```

The scratch key only lives for that one launch, so treat a scratch journal as
disposable: start each session with a fresh directory (`rm -rf /tmp/omega-dev`).

## Project layout

```
Sources/OmegaJournalCore/   Pure, unit-testable logic (no AppKit, no database):
                            search sanitizing, Markdown helpers, date grouping…
Sources/OmegaJournal/       The app
  Data/                     DatabaseManager (all SQL), encryption, backups
  ViewModels/               JournalViewModel — the single source of UI state
  Views/                    SwiftUI views, grouped by area (Browse, Editor, …)
Tests/OmegaJournalTests/    Swift Testing suites
```

Data flows one way: `DatabaseManager` → `JournalViewModel` → views. Views never
run SQL directly.

`AGENTS.md` holds the deeper architectural rules (autosave race handling, the
dual tag store, the launch gate). Please skim it before touching `Data/` or
`ViewModels/`.

## Tests

- We use **Swift Testing** (`@Suite`, `@Test`, `#expect`) — please don't add XCTest.
- Prefer putting new logic in `OmegaJournalCore` so it can be tested without UI.
- **Critical:** any test that creates `DatabaseManager()` or `JournalViewModel()`
  must first point `OMEGA_JOURNAL_TEST_DATABASE_PATH` (and
  `OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH`) at a unique temp directory. See
  `Tests/OmegaJournalTests/ArchiveTrashLifecycleTests.swift` for the pattern.
  Database suites use `.serialized`.
- Bug fixes should come with a test that fails before the fix.

## Pull requests

1. Fork, create a branch, make your change.
2. Run `swift build && swift test` — CI runs the same on every PR.
3. For UI changes, include a before/after screenshot. **Use demo content only —
   never screenshots of a real journal.**
4. Use a conventional commit prefix (`feat:`, `fix:`, `docs:`, `test:`) and
   explain the *why* (the root cause), not just the symptom.
5. Keep PRs focused; small PRs get reviewed quickly.

## Design principles

- **Writing first.** The fastest path should always be "open the app → write".
- **Local-first and honest about privacy.** Don't add network calls, analytics
  or accounts. If a feature has a privacy limit, document it.
- **Native and accessible.** Use system controls, support VoiceOver labels,
  keyboard navigation, Dynamic Type-friendly fonts and Reduce Motion.
- **Calm UI.** Fewer, clearer controls beat more icons.

## Reporting bugs and security issues

Use the issue templates for bugs and feature ideas. For anything that could
expose someone's journal content, please follow [SECURITY.md](SECURITY.md)
instead of opening a public issue.

By contributing you agree your work is released under the [MIT License](LICENSE)
and that you'll follow our [Code of Conduct](CODE_OF_CONDUCT.md).
