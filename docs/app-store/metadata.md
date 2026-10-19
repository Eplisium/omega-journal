# App Store metadata (draft)

Character limits are App Store Connect's. Counts were checked with a script; re-check after edits.

## Name (≤30)

```
Omega Journal
```

## Subtitle (≤30)

```
Private, encrypted Mac diary
```

## Promotional text (≤170, editable any time without review)

```
A calm, private place to write. Your journal never leaves your Mac: entries are encrypted, there are no accounts, and nothing is tracked. Just you and the page.
```

## Description (≤4000)

```
Omega Journal is a private journal made for the Mac. Write every day, look back on what mattered, and know that your words stay on your computer.

PRIVATE BY DESIGN
• No account, no sign-in, no cloud, no tracking. The app never connects to the internet.
• Entry text, attachments and backups are encrypted on your Mac with Apple CryptoKit.
• Hide sensitive entries and unlock them with Touch ID or your Mac password.

A WRITING SPACE THAT GETS OUT OF THE WAY
• A fast native Markdown editor with live preview, split view and a distraction-free Zen mode.
• Headings, lists, checklists, quotes and links, with keyboard shortcuts for all of them.
• Templates and gentle prompts for days when the page feels blank.
• Attach photos and files, or record a voice memo straight into an entry.

ORGANIZE YOUR WAY
• Notebooks, nested tags, moods and favorites.
• Smart folders that update themselves from a saved search.
• Powerful search with filters like tag:, mood:, before:, after: and has:.
• Link entries together and follow backlinks.
• A command palette (⌘K) to jump anywhere.

REFLECT AND BUILD A HABIT
• Today view with a single place to start writing.
• Calendar, On This Day, weekly and monthly reviews, and a year in review.
• Insights into your moods, writing rhythm and streaks, all computed on your Mac.
• Optional daily writing goals and reminders.

YOUR DATA STAYS YOURS
• Automatic daily backups, plus an optional extra backup folder you choose.
• Export to Markdown, JSON, HTML, PDF or a password-protected archive at any time.
• Import Markdown and text files, notes folders, and JSON exports from other journal apps.

Made for macOS 14 Sonoma and later, on Apple silicon and Intel Macs.
```

> Check every feature line against the shipping build before submitting (App Review rejects
> descriptions that promise missing features). Don't name other apps (Day One, Obsidian) in
> metadata: guideline 2.3.7 treats third-party names as keyword stuffing.

## Keywords (≤100, comma-separated, no spaces needed)

```
diary,journaling,private,encrypted,mood,tracker,markdown,gratitude,reflection,notes,writing,offline
```

## URLs

- Support URL: `https://unknownprojects.net/omega-journal/support` ([support.md](support.md))
- Privacy Policy URL: `https://unknownprojects.net/omega-journal/privacy` ([privacy-policy.md](privacy-policy.md))
- Marketing URL (optional): `https://unknownprojects.net/omega-journal`

## Category

- Primary: **Lifestyle** (matches `LSApplicationCategoryType = public.app-category.lifestyle`)
- Secondary: **Productivity**

## Copyright

```
2026 Zach Gladfelter
```

## Price

**$2.99** (USD base price); all storefronts; no in-app purchases; no subscriptions.

## Age rating questionnaire

Answer **None / No** to every content question:

| Question | Answer |
|---|---|
| Parental controls / age assurance built in | No |
| Unrestricted web access | No |
| User-generated content shared with others | No (entries are private, never shared or published) |
| Messaging and chat | No |
| Advertising | No |
| Cartoon/fantasy/realistic violence, prolonged graphic violence | None |
| Sexual content, nudity, graphic sexual content | None |
| Profanity or crude humor | None |
| Alcohol, tobacco, drug use or references | None |
| Mature/suggestive themes, horror/fear themes | None |
| Medical or treatment information | None (the mood log is not medical advice) |
| Gambling, simulated gambling, contests | None / No |
| Health or wellness topics | No |
| Loot boxes | No |

Expected result: **4+**.

## App Privacy ("nutrition label")

- *Do you or your third-party partners collect data from this app?* → **No, we do not collect data from this app.**
- Shown on the store as **Data Not Collected**.
- Reason this is accurate: no networking at all, no analytics/crash SDKs, everything stays on device. `PrivacyInfo.xcprivacy` declares no collected data types and no tracking.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is in Info.plist, so App Store Connect normally doesn't ask.
If it does:

1. *Does your app use encryption?* → **Yes** (it encrypts the user's journal at rest).
2. *Which type of encryption algorithms does your app implement?* → **None of the algorithms mentioned above**, meaning it uses only the encryption built into Apple's operating system (CryptoKit AES-GCM, CommonCrypto PBKDF2) and implements no proprietary or standalone standard crypto.
3. No export documentation is needed; it is not distributed in France with special requirements.

## What's New (version 1.1.0)

Not shown for an app's first App Store version; keep it for the first update.

```
Omega Journal is now on the Mac App Store. If you used an earlier version on this Mac, your journal comes along automatically the first time you open the app.
```
