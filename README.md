# Omega Journal

A beautiful, production-quality journaling app for macOS, built with SwiftUI and SQLite.

![Omega Journal](Omega%20Journal.app/Contents/Resources/AppIcon.icns)

## Features

- **Native macOS experience** — Three-column layout with sidebar, entry list, and detail view
- **SQLite database** — All entries stored locally in a SQLite database (no cloud, no accounts)
- **Mood tracking** — 5-level mood system (😞 → 😄) with color-coded indicators and weekly stats
- **Tags** — Organize entries with tags; flow-layout tag chips in both list and editor
- **Pin & Favorite** — Keep important entries at the top
- **Full-text search** — Search across titles, body text, and tags
- **Auto-save** — Entries save automatically as you type (0.8s debounce)
- **Writing streak** — Tracks consecutive days of journaling
- **Statistics** — Total entries, this week, average mood, total words, writing streak
- **Sort options** — By date (newest/oldest) or title (A→Z / Z→A)
- **Keyboard shortcuts** — ⌘N for new entry, ⌘⌫ for delete, ⌘↩ to finish editing
- **Custom app icon** — The Greek letter Ω on a gradient background

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 26 / Swift 6.3

## Building

```bash
cd OmegaJournal
swift build
bash build_app.sh
open "Omega Journal.app"
```

## Architecture

| File | Responsibility |
|------|---------------|
| `Sources/OmegaJournal/DatabaseManager.swift` | SQLite3 C API wrapper, CRUD operations, schema management |
| `Sources/OmegaJournal/Models.swift` | Data models (JournalEntry, Mood, SortOrder), ViewModels |
| `Sources/OmegaJournal/OmegaJournalApp.swift` | SwiftUI views: sidebar, entry list, editor, settings |

The app uses:
- **SwiftUI** for the entire UI (NavigationSplitView, three-column layout)
- **SQLite3** C library (built into macOS) for persistent storage — no external dependencies
- **WAL mode** for concurrent read/write performance
- **Debounced auto-save** to prevent excessive database writes

## Database

Entries are stored at:
```
~/Library/Application Support/OmegaJournal/omega_journal.sqlite3
```

The database uses WAL (Write-Ahead Logging) for performance and has two tables:
- `entries` — journal entries with title, body, mood, tags, timestamps, pin/favorite flags
- `settings` — key-value store for app preferences

## License

MIT
