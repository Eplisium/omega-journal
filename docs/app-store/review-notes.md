# App Review notes

*Paste the block below into App Store Connect → version page → App Review Information → **Notes**.
Sign-in required: **No**. Contact: Zach Gladfelter, support@unknownprojects.net (TO CONFIRM), phone (fill in).*

---

Thank you for reviewing Omega Journal.

Omega Journal is a private, offline journal for the Mac. There is no account, no sign-in, no server and no network access. Everything is stored in the app's sandbox container, and entry text, attachments and backups are encrypted at rest with Apple CryptoKit.

How to try the main features (no setup needed):
1. Launch the app. A short welcome tour appears; click Skip or Next.
2. Click "New Entry" (⌘N), type a title and some text. Changes save automatically.
3. Add a tag and a mood in the editor. Try ⌘K (command palette) and ⌘F (search, e.g. "tag:test").
4. Voice memo: in the editor, open the "More" menu → "Record Voice Memo…". macOS asks for microphone permission. The microphone is used only while recording a memo, and the recording is stored encrypted with that entry.
5. Hidden entries: in the reader, use "More" → "Hide". The entry becomes a masked card. Clicking it asks for Touch ID or the Mac password through the standard macOS LocalAuthentication prompt. ⌘L locks it again.
6. Files: attachments, import, export (Markdown, JSON, PDF, password-protected export) and the optional backup folder all use the standard open/save panels. The app only accesses what the user picks.
7. Calendar, Insights and On This Day (sidebar) summarize entries locally.

Permissions and entitlements:
- Microphone (com.apple.security.device.audio-input): voice memos only.
- User-selected files + app-scoped bookmarks: import/export/attachments and remembering the user's chosen backup folder.
- Print: printing a single entry.
- No network entitlements. The app makes no network requests.

Encryption: the app uses only encryption provided by Apple's operating system (CryptoKit, CommonCrypto) to protect the user's own data on their Mac. ITSAppUsesNonExemptEncryption is set to NO.

Data: the app collects no data. No analytics, advertising, tracking or third-party SDKs.

Some menu items mention "On-Device Writing Help". It uses Apple's on-device Foundation Models only where the Mac supports Apple Intelligence; on other Macs the option is unavailable.
