<p align="center">
  <img src="docs/icon.png" width="168" alt="Omega Journal">
</p>

<h1 align="center">Omega Journal</h1>

<p align="center">
  <strong>A fast, private, local-first journal for macOS.</strong><br>
  Write freely. Stay on this Mac. Unlock the rest when you mean to.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-7C83DB?style=flat-square">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-native-7C83DB?style=flat-square">
  <img alt="SQLite" src="https://img.shields.io/badge/storage-SQLite-7C83DB?style=flat-square">
  <img alt="No cloud" src="https://img.shields.io/badge/cloud-none-7C83DB?style=flat-square">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-7C83DB?style=flat-square">
</p>

---

Omega Journal is a three-column native app for people who want a real writing space — not a website with a login. Entries live in a SQLite database on your machine. There is no account, no sync, and no one else in the room unless you unlock them.

## Why it feels like yours

| | |
|---|---|
| **Local-first** | Everything stays in `~/Library/Application Support/OmegaJournal/`. No cloud, no telemetry. |
| **Hidden, not gone** | Mark an entry hidden and it stays in your list as a locked card. Touch ID, Face ID, or your Mac password reveal the body. |
| **Walk-by lock** | ⌘L remasks every hidden entry. Switching away from the app locks them too. |
| **Write without fuss** | Autosave, markdown, zen mode, templates, and a daily prompt when the page is blank. |
| **See the year** | Calendar, insights, a contribution heatmap, mood trends, streaks, and On This Day. |

## What you can do

- **Three-column layout** — library sidebar, entry cards, and a reader / editor that stays out of the way
- **Markdown editor** — live preview, split view, formatting shortcuts, attachments
- **Moods** — 😞 😕 😐 🙂 😄, color-coded in the list and charted in Insights
- **Tags, pins, favorites** — keep the important pages close
- **Archive & trash** — archive to clear the main list; trash keeps entries for 30 days
- **Hidden entries** — locked cards in All Entries until you authenticate; re-lock with ⌘L
- **Full-text search** — FTS5 across titles and bodies, with hidden bodies excluded until unlock
- **Command palette** — ⌘K to jump, create, theme, export
- **Templates & prompts** — start structured, or answer today's question
- **Import / export** — Markdown, JSON backup, and printable PDF
- **Themes** — dark, light, and custom palettes
- **Daily backups** — automatic SQLite snapshots, last 7 kept

## Quick start

```bash
cd OmegaJournal
swift build
swift test
bash build_app.sh
open "Omega Journal.app"
```

`swift build` compiles. `build_app.sh` packages the newest binary into **Omega Journal.app** (note the space) and generates the Ω icon.

**Needs** macOS 14 Sonoma or later, and a recent Swift toolchain (Xcode 15+).

## Everyday shortcuts

| | |
|---|---|
| ⌘N | New entry |
| ⇧⌘N | New from template |
| ⌥⌘N | New from today's prompt |
| ⌘K | Command palette |
| ⌘F | Search |
| ⌘E | Edit selected entry |
| ⌘L | Lock hidden entries |
| ⌃⌘F | Zen mode |
| ⌘B / ⌘I | Bold / italic |
| ⌘⏎ | Finish editing |
| ⎋ | Close editor or palette |

## Where the words live

```
~/Library/Application Support/OmegaJournal/
├── omega_journal.sqlite3      # your journal (WAL mode)
├── attachments/               # files you drop onto an entry
└── backups/                   # automatic daily copies
```

Schema version lives in a `schema_version` table. Current version is **V7** (hidden entries). Foreign keys are on. Trash is a soft delete.

## Architecture

```
Sources/
├── OmegaJournalCore/     Pure logic (FTS sanitizer, markdown import, fuzzy match)
└── OmegaJournal/         SwiftUI app + SQLite3 C API
```

```
SQLite  ←→  JournalViewModel  ←→  SwiftUI
```

No third-party packages. SwiftUI for the chrome, the system SQLite library for the store, LocalAuthentication for hidden entries.

| Piece | Role |
|---|---|
| `DatabaseManager.swift` | Connection, migrations, CRUD, FTS, backups |
| `JournalViewModel.swift` | All published state and actions |
| `EntryListView.swift` | Cards, search, filters, locked-row chrome |
| `ReadView.swift` / `EditorView.swift` | Reader overlay + markdown editor |
| `BiometricAuth.swift` | Session unlock / lock |
| `InsightsView.swift` / `CalendarView.swift` | Heatmap, charts, month browser |

## Privacy, plainly

Hidden is a content gate, not a disappearing act. Locked cards stay in All Entries, Calendar, and search (title only) so the library still makes sense. Bodies, tags, attachments, copy, duplicate, and export wait for authentication. Leave the app, or hit ⌘L, and they go quiet again.

## License

[MIT](LICENSE) — use it, fork it, keep your journal yours.
