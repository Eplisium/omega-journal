# Omega Journal — Features & UI Upgrade Plan

> **For Hermes:** execute phase by phase, one subagent per task, `swift build && swift test` green before each commit. Follow `AGENTS.md` (test isolation env vars, autosave-flush rule, transactions, migrations idempotent).

**Goal:** Turn Omega Journal from a solid local-first journal into a standout native Mac app: better writing experience, real reflection tools, a more polished/consistent UI, while keeping the privacy/no-cloud identity.

**Current state (inspected):** ~16k LOC SwiftUI + raw SQLite, schema V9, FTS5, encrypted bodies at rest, hidden entries w/ Touch ID, markdown editor (tables, tasks, wiki links, paste-image), Today/Journal/Calendar/Insights/On This Day, ⌘K palette, menu-bar quick capture, templates/prompts, saved searches, weekly review drafts, JSON/MD/PDF export, daily backups, 5-mood scale, custom themes. Suite of ~23 test files.

**Observed gaps:**
- Design tokens (`OmegaTheme.swift`) are tiny (5 fonts, 4 radii). Hardcoded `.font(.system(size:))` is spread widely (EntryListView 58, CalendarView 52, Insights 47, Today 39, Settings 30) → inconsistent type, no Dynamic-Type-style scaling, tiny 10pt meta fonts.
- Giant files: DatabaseManager 1956, JournalViewModel 1472, Insights 1038, Calendar 1017, EntryListView 953 — hard to extend.
- Single mood scalar; no structured check-ins, no habits/metrics, no media beyond attachments, no per-entry linking graph, no sync/backup-to-user-chosen location, no iOS companion.
- Wiki links + backlinks exist in core but are likely under-surfaced in UI.

---

## Phase 0 — Foundations (1–2 days) — do first, unblocks everything
1. **Design system pass.** Expand `OmegaTheme.swift`: type scale (caption/meta/body/bodyLarge/heading/title/display), spacing scale (4/8/12/16/24/32), radii, shadow/elevation, animation presets, semantic colors (success/warn/danger, surface levels 0–3). Add `OmegaCard`, `OmegaChip`, `OmegaSectionHeader`, `OmegaEmptyState`, `OmegaIconButton` components.
2. **Replace hardcoded fonts** file-by-file with tokens (min meta size 11pt). Verify with `grep -c "font(.system(size"` trending to ~0 outside the theme.
3. **Split mega files** (no behavior change): `DatabaseManager` → +Entries/+Tags/+FTS/+Migrations/+Backup extensions; `JournalViewModel` → +Mutations/+Search/+Import; `EntryListView` → Row/Filters/Toolbar. Tests must pass untouched.
4. **Theme upgrade.** Ship ~8 curated presets (Midnight, Paper/light, Sepia, Forest, Ocean, Rose, Mono, High-contrast), follow-system toggle, contrast check on custom colors (WCAG ratio warning).

Files: `OmegaTheme.swift`, `ThemeManager.swift`, new `Components/*.swift`, all view files. Tests: contrast helper in Core + unit tests; existing suites.

## Phase 1 — Writing experience (highest daily value)
1. **Focus/Typewriter mode:** typewriter scroll, paragraph dimming, adjustable column width, font choice (serif/sans/mono/system), line height. (`MarkdownTextEditor.swift`, `ReadingPreferences.swift`, `EditorView.swift`)
2. **Slash-commands & inline `[[` autocomplete** popover (wiki links already parse in Core) — headings, task, quote, table, date, mood, template snippet.
3. **Live word/goal ring + session stats** in editor footer; session timer; optional "writing sprint" (10/20 min).
4. **Version history per entry:** new table `entry_revisions` (V10), snapshot on edit-session end (throttled), diff + restore UI. Encrypted like bodies.
5. **Rich media:** inline image rendering in reader/preview with resize, audio memo attachment (AVAudioRecorder) with waveform, location/weather stamp (optional, off by default, CoreLocation/WeatherKit-free → just user-typed or MapKit reverse geocode).
6. **Templates v2:** variables (`{{date}}`, `{{prompt}}`, `{{mood}}`), user-editable library UI, per-template default tags.

Tests: Core logic for slash parsing, revision pruning policy, template variable expansion; round-trip export includes revisions flag.

## Phase 2 — Organization & discovery
1. **Backlinks panel + Graph view** in reader (list first; force-directed graph later). Unlinked mentions suggestions.
2. **Smart collections:** saved searches promoted to sidebar "Smart Folders" (tag + mood + date range + has-attachment + word-count) with live counts. Builds on `saved_searches_v1`.
3. **Search upgrade:** highlighted snippets, filters chips (`tag:`, `mood:`, `before:`, `has:image`), recent searches, ⌘K palette searches entry content.
4. **Tag manager:** colors, merge, rename (rename exists), nested tags `a/b`, tag autocomplete in editor.
5. **Multi-select & bulk actions** polish in list; drag entries to tags/archive in sidebar.
6. **Journals/notebooks** (V11): multiple journals (e.g. Personal, Work, Dreams) with per-journal color and optional separate hidden lock. Biggest schema change — do after Phase 1, design carefully with migration from single implicit journal.

## Phase 3 — Reflection & insights
1. **Structured daily check-in:** sleep, energy, stress, custom metrics (V12 `metrics` + `entry_metrics`), shown on Today; correlations in Insights (mood vs. sleep/tags/weekday).
2. **Habit tracker** strip (checkbox habits per day) feeding the heatmap and Insights.
3. **Insights upgrade:** word-cloud/top-themes (local NLTagger/NaturalLanguage sentiment + keywords — on-device only), mood-by-weekday, streak history, year-in-review page (exportable PDF/image).
4. **Weekly/monthly review** (draft generator exists in `JournalFeatures.swift`): scheduled prompt via `NotificationManager`, one-click save as entry.
5. **On This Day v2:** multi-year carousel, "a year ago" widget on Today.
6. **Optional on-device AI** (Apple Intelligence / Foundation Models when available, strictly opt-in, never sends data off-device): summarize entry, suggest title/tags, reflective prompts. Gate behind macOS availability checks; hidden entries excluded unless unlocked and user opts in.

## Phase 4 — UI polish & native feel
1. **Sidebar redesign:** collapsible sections with persisted state, counts as subtle badges, pinned smart folders, tag color dots.
2. **Entry list:** density toggle (compact/comfortable/cards), thumbnail for first image, mood color rail, date-group headers (Today/Yesterday/This week), hover quick actions.
3. **Reader:** readable column, typographic scale, cover image option, table of contents for long entries, print-quality styles.
4. **Today dashboard:** greeting, streak ring, prompt card, check-in, on-this-day, recent — reduce visual noise; consistent card system.
5. **Motion:** matched transitions between list↔reader, spring on mood picker, reduce-motion respected (`accessibilityReduceMotion`). Tone down hover scale/glow to subtle.
6. **Accessibility:** VoiceOver labels audit on all icon buttons, keyboard navigation for list/sidebar, full keyboard focus rings, contrast, Reduce Transparency.
7. **Onboarding & empty states:** first-run tour (3 cards), illustrated empty states via `OmegaEmptyState`, "what's new".
8. **Menu bar & Dock:** Quick capture improvements (mood + tag), Dock menu "New entry", global hotkey (e.g. ⌥⌘J), Spotlight indexing of non-hidden titles (CoreSpotlight).

## Phase 5 — Data, safety, platform
1. **Backup UX:** choose backup folder (iCloud Drive/external), restore-from-backup UI, integrity check button, encrypted export (passphrase).
2. **Import:** Day One JSON, Apple Notes/Obsidian folder, plain-text folder.
3. **Export:** per-entry/PDF themed, full static-site/HTML export, Markdown with front-matter + attachments folder.
4. **App lock for whole app** (not just hidden): optional launch lock, auto-lock timer settings.
5. **Optional sync (long-term):** CloudKit private DB or file-based sync via iCloud Drive with end-to-end encryption — only after notebooks + revisions are stable. Needs its own design doc; keeps "local-first" promise.
6. **iOS companion** (SwiftUI shared Core package) — separate project plan; Core package already isolates logic.

---

## Suggested sequencing
| Order | Work | Why |
|---|---|---|
| 1 | Phase 0 | Cheap, makes every later UI task consistent |
| 2 | Phase 1.1–1.3, 1.6 | Most visible daily improvements, no schema risk |
| 3 | Phase 4.1–4.4 | Visible UI payoff while schema stays stable |
| 4 | Phase 2.1–2.4 | Leverages existing wiki link/FTS/saved-search code |
| 5 | Phase 1.4, 3.1–3.4 | Needs migrations V10–V12; plan one combined migration review |
| 6 | Phase 2.6 notebooks, Phase 5 | Largest risk; do last |

## Per-task workflow
1. Read nearest `AGENTS.md` + skill `omega-journal-development` (entry-property checklist for any new column).
2. Failing test first (Swift Testing; temp DB via `OMEGA_JOURNAL_TEST_DATABASE_PATH` / `..._ATTACHMENTS_PATH`).
3. Implement; any immediate mutation goes through `flushBeforeImmediateMutation()`; multi-statement writes in `beginTransaction`.
4. `swift build && swift test`; for UI tasks `bash build_app.sh`, open app, screenshot light + dark + custom theme, check Reduce Motion.
5. Commit per task (`feat:`/`refactor:`), push only when Zach asks.

## Risks / open questions
- **Migrations touch real data**: back up DB before each migration test; make idempotent; V8 encrypted bodies mean new body-bearing tables (revisions) must use the same encryption path.
- **Hidden entries leakage**: every new surface (search snippets, graph, Spotlight, AI, revisions, widgets) must respect masking — add a test per surface.
- **Mega-file refactor** can conflict with parallel agents; do Phase 0.3 solo, then parallelize.
- Notebooks and sync are product decisions — need Zach's call.

**Questions for Zach:** (1) Is iOS/sync on the roadmap or stay Mac-only? (2) OK with opt-in on-device AI features? (3) Preferred visual direction — keep purple/dark glow, or move toward calmer "paper" look? (4) Notebooks wanted?
