# App Store screenshots

**Never photograph a real journal.** Every screenshot comes from a synthetic demo journal
in a throwaway database (the same method used for `docs/screenshots/`).

## Required sizes (Mac, 16:10)

Upload 1–10 screenshots, all the same size, as PNG or JPEG with no transparency. Accepted sizes:

| Size (px) | Notes |
|---|---|
| **2880 × 1800** | recommended: Retina, crisp on every store page |
| 2560 × 1600 | Retina |
| 1440 × 900 | non-Retina |
| 1280 × 800 | minimum |

App Store Connect scales down from the largest set, so one 2880 × 1800 set is enough.

## Shot list (suggested order)

1. **Today**: "Write" card plus recent entries. Caption: *A calm place to start writing.*
2. **Editor**: split view with Markdown on the left and the preview on the right. Caption: *Native Markdown, distraction-free.*
3. **Reader with a hidden entry masked**, plus the Touch ID prompt if it can be captured cleanly. Caption: *Private entries stay locked.*
4. **Calendar**. Caption: *See your writing by day.*
5. **Insights** (moods and rhythm). Caption: *Gentle insights, computed on your Mac.*
6. **Search with operators** (`tag:travel`, `has:image`). Caption: *Find anything instantly.*

Captions are optional. If you add them, overlay them in a design tool afterwards. Keep the app
UI itself real (Guideline 2.3.3: screenshots must show the app in use).

## How to produce them

The demo seeder lives in the Hermes skill:
`~/.hermes/skills/software-development/omega-journal-development/scripts/seed_demo_journal.py`.
It refuses any path containing `Application Support/OmegaJournal`. Use the **direct** dev build
for screenshots; it looks identical to the App Store build and isn't sandboxed, so the demo database
can live in a scratch folder.

```bash
cd ~/OmegaJournal && bash build_app.sh
D=~/.hermes/cache/scratch/oj-appstore-shots && rm -rf "$D" && mkdir -p "$D"
APP="Omega Journal.app/Contents/MacOS/OmegaJournal"

# 1. Create the demo schema (test mode = ephemeral key; real journal and Keychain untouched)
OMEGA_JOURNAL_TEST_DATABASE_PATH="$D/journal.sqlite3" OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH="$D/att" "$APP" &
sleep 8; kill %1

# 2. Seed synthetic entries
python3 ~/.hermes/skills/software-development/omega-journal-development/scripts/seed_demo_journal.py "$D/journal.sqlite3"

# 3. Relaunch on the demo journal
OMEGA_JOURNAL_TEST_DATABASE_PATH="$D/journal.sqlite3" OMEGA_JOURNAL_TEST_ATTACHMENTS_PATH="$D/att" "$APP" &
```

Then, for each shot:

1. Make the window exactly **1440 × 900 points**. On a Retina display a window capture is then 2880 × 1800 px plus the shadow. Set it with System Events or the AX size attribute; the app's minimum is 940 × 672.
2. Skip the onboarding tour, navigate to the screen, and park the pointer on empty space (hover reveals row buttons and tooltips).
3. Capture only the window, without the shadow: `screencapture -o -x -l <CGWindowID> shot-1.png`. The window ID comes from `CGWindowListCopyWindowInfo` filtered by the app's pid.
4. Check the size with `sips -g pixelWidth -g pixelHeight shot-1.png`. If it is off by a few pixels, resize to the exact size: `sips -z 1800 2880 shot-1.png`. Never crop the UI.
5. Look at every PNG at full size for raw Markdown, glitches, debug banners or anything that looks like real personal data.

Use **Light** and **Dark** consistently across the set (Dark matches the app's default look).
Quit the demo instance afterwards (`kill %1`) and delete `$D`.
