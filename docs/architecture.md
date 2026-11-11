# Architecture

This is a short map of how Omega Journal fits together. It's for contributors who need to
find the right file and keep the privacy rules intact. `AGENTS.md` has the build commands.
The code comments are the source of truth for details.

## Targets

`Package.swift` builds one SwiftPM package. It targets macOS 14+, uses the Swift 6 language
mode with full data-race checking, and has no third-party dependencies.

| Target | Kind | What lives there |
|---|---|---|
| `OmegaJournalCore` | library | Pure logic with no UI and no database: Markdown, search operators, streaks and stats, import parsers, export formats, smart folders, layout policies, `PassphraseVault`. Nonisolated. Most unit tests cover this target. |
| `OmegaJournalShared` | library | Code the app and the widget both use: `WidgetSnapshot` (the only data the widget ever sees), App Group plumbing and `omegajournal://` deep links. Foundation only. |
| `OmegaJournalWidgetUI` | library | Widget SwiftUI views. They live outside the extension so tests can render them. |
| `OmegaJournal` | executable | The app: SwiftUI views, view models, SQLite data layer, encryption, services and App Intents. Main-actor isolated by default. |
| `OmegaJournalWidgets` | executable | The WidgetKit extension. It uses extension-safe API only, with entry point `NSExtensionMain`. The packaging scripts wrap it in `Contents/PlugIns/OmegaJournalWidgets.appex`. |
| `OmegaJournalTests` | tests | Swift Testing suites for every target. |

There is no Xcode project. `build_app.sh` (direct/dev), `scripts/make_release.sh`
(notarized DMG) and `scripts/make_mas.sh` (App Store `.pkg`) assemble and sign the bundle.
They share their logic in `scripts/lib/oj-packaging.sh`. Info.plist keys, entitlements and the
privacy manifest are templates in `packaging/`.

## App layout (`Sources/OmegaJournal`)

- `App/`: `OmegaJournalApp` (the main window, Settings, the Quick Capture menu bar extra and
  the app delegate), `LaunchGateView`, `ContentView` (the split shell) and onboarding.
- `Data/`: `DatabaseManager` and its extensions (entries, tags, search, attachments,
  backups, migrations), `JournalCrypto` (`Encryption.swift`), import/export, revisions,
  and the App Store data and key migration (`MASData*`).
- `ViewModels/`: `JournalViewModel`, an `@Observable` split across `+Mutations`,
  `+Search`, `+Stats` and other extensions, plus smaller view models for tags, revisions,
  smart folders and writing.
- `Views/`: Browse, Calendar, Editor, Insights, Reading, Settings, Today and shared components.
- `Services/`: hidden-entry lock (`BiometricAuth`), App Lock, notifications, Spotlight,
  global hotkey, on-device AI (`SmartAssist`), writing goals and audio.
- `Intents/`: App Intents (Siri and Shortcuts), the command inbox and the widget snapshot
  publisher.

## Data flow

```
View ── reads ──▶ JournalViewModel (@Observable, main actor) ── calls ──▶ DatabaseManager
  ▲                     │  in-memory entries, filters, derived stats          │ SQLite (WAL), main actor
  └──── observes ───────┘                                                    ▼
                                         journal.sqlite3 + attachments/ + backups/
                                         (Application Support/OmegaJournal, or the
                                          sandbox container in the App Store build)
```

- **One connection.** The SQLite handle lives on the main actor. Heavy work such as
  importing, exporting, indexing and AI reads its inputs on the main actor, then runs
  off-main.
- **Autosave.** The editor writes into a pending snapshot that the view model flushes on a
  debounce. It also flushes before anything that could lose the edit: switching or closing
  an entry, trashing, reloading, quitting, or switching notebooks. A failed save stays
  visible as an unsaved state and never drops text.
- **Derived surfaces read from the view model, never straight from the database.** These
  are Today, Insights, Calendar, the widget snapshot, Spotlight and App Intents. They all
  apply the same hidden-entry masking.
- **The widget** sees only `WidgetSnapshot`. It holds counts, a streak, dates and the day's
  prompt, and never titles, bodies, tags, moods or anything from a hidden entry. The app
  writes the snapshot into the App Group container, and the sandboxed extension only reads it.

## Encryption model

All cryptography is Apple's: CryptoKit `AES.GCM` and CommonCrypto `PBKDF2`. No crypto code
is bundled or custom-written. The purpose is to protect the user's own data on their own
Mac, which is also why the export-compliance answer is "exempt" (see
[app-store/SUBMISSION.md](app-store/SUBMISSION.md#export-compliance)).

**Key.** There is one random 256-bit key, stored in the Keychain as a generic password. It
is written to disk only in Keychain storage. The App Store build reads the data-protection
keychain group first and falls back to the legacy login keychain item that direct builds
use. `MASDataKeyResolver` handles the lookup. The app never mints a key while any open
database holds encrypted data, because that would make the data unreadable.

| Data | At rest |
|---|---|
| Entry bodies (`entries.body`) | **Encrypted**, AES-GCM per row |
| Revision bodies (`entry_revisions.body_enc`) | **Encrypted** |
| Attachment files (images, voice memos, files) | **Encrypted**, AES-GCM per file. Opening one in another app writes a short-lived decrypted copy into a private (0700) temp folder, and crash leftovers are swept. |
| Automatic backups | **Encrypted** whole-file |
| `.ojenc` exports | **Encrypted** with a passphrase key (PBKDF2-HMAC-SHA256 to AES-GCM). This key is independent of the Keychain key, so the archive opens on any Mac. |
| Titles, tags, moods, dates, flags (pinned, favorite, hidden, archived, trashed), notebook names | **Plaintext** metadata in SQLite |
| Full-text index (`entries_fts`) | Titles and tags only (plaintext). Bodies are never indexed. Migrations purge postings that older builds left, and FTS5 secure-delete is on where SQLite supports it. |
| Check-ins, metrics, habits, templates, settings | **Plaintext** |
| Plain exports (Markdown, JSON, HTML, PDF) | Plaintext. The user chooses the destination. |

Body search decrypts in memory. Titles, tags and other metadata are readable by anything
that can read the database file, and the UI copy says so: "Entry bodies are encrypted".
Encrypting metadata would mean a schema change plus an in-memory index, and it is not done
today.

**Hidden entries** use a visibility lock, not a second key. `BiometricAuth` (Touch ID or
the account password through `LAContext`) unlocks them per session. While locked, every
surface masks them: lists, search, Today, Insights, goals, Spotlight, widgets, Siri, AI and
export previews. **App Lock** is a separate gate over the whole window.

## Launch gate

`LaunchGateView` is the first thing the window shows. Building `ContentView` opens the
database and decrypts entries, which needs the Keychain key. When macOS asks the user to
allow that access, the read blocks. The gate therefore:

1. draws a window right away and never touches the database itself;
2. fetches the **existing** key on a background thread, in load-only mode, so it never mints one;
3. only then builds `ContentView` (wrapped in the App Lock gate) and the data layer.

The launch gate must never open the database or mint a key. An unwritable journal opens
read-only with an explanation.

## On-device AI and privacy

- `SmartAssist` uses Apple's on-device Foundation Models only. It is off by default
  (opt-in in Settings), refuses hidden and empty entries, and hides itself when the model
  isn't available. Insights "Themes & tone" uses Apple's NaturalLanguage framework on the Mac.
- Spotlight indexing is opt-in and indexes non-hidden titles only. It never indexes bodies
  or tags.
- The app has no networking code. Nothing leaves the Mac unless the user exports, shares
  or prints. `packaging/PrivacyInfo.xcprivacy` declares no tracking and no collected data.

## Testing

`swift test` runs Swift Testing suites. Most cover `OmegaJournalCore` directly. App-level
suites drive `JournalViewModel` and `DatabaseManager` against temporary databases and never
touch the real journal or the real Keychain.

- **Test mode.** When `OMEGA_JOURNAL_TEST_DATABASE_PATH` is set, `.shared` singletons open
  that path, and `JournalCrypto` uses an ephemeral in-memory key.
  `TestSharedEnvironment.pin()` points both test variables at a single directory for the
  whole run, which is never deleted mid-run. Every suite that may reach a `.shared`
  singleton calls it first.
- **Private journals.** A test that asserts on counts, empty lists or settings builds its
  own `DatabaseManager(databasePath:attachmentsPath:)`, passes it to
  `JournalViewModel(database:)`, and deletes the directory afterwards.
- **Process-wide state.** `.serialized` only orders tests inside one suite.
  `BiometricAuth.shared` (the hidden-entry lock) is global, so suites that flip it or
  assert on masking through a view model carry `.lockState`. That trait gives each of
  their test cases one process-wide mutex, while every other suite still runs in parallel.
- **Determinism.** Date logic takes explicit calendars and time zones. Layout tests don't
  depend on this Mac's fonts or scroller style. Code that needs macOS 26 frameworks is
  tested through a seam.

Locally, `swift test` runs in parallel. That is the default and it is how the suite is
kept honest. CI still runs `swift test --no-parallel`: parallel runs are proven on a
developer Mac but not yet on the smaller CI runners, and new suites must be checked for
`.lockState` first. Drop the flag once parallel CI has run green for a while.

CI (`.github/workflows/ci.yml`) runs on `macos-26` with a pinned Xcode and has four jobs:

- **Build and test.** Builds with the warnings gate (`scripts/check_warnings.sh`, baseline
  in `scripts/warnings-baseline.txt`), then runs the tests. `.build` is cached per
  toolchain, and `scripts/restore_mtimes.py` makes the cache usable after checkout.
- **Package.** Builds `build_app.sh` and `make_mas.sh --dev` ad-hoc signed, with no
  secrets, and checks both bundles with `scripts/verify_bundle.sh`. That script also runs
  locally on any built app.
- **SwiftLint.** `.swiftlint.yml` enables correctness rules only. The job reports findings
  and never fails.
- **Script checks.** ShellCheck and Python syntax checks for the CI scripts.
