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
8. On-device writing help (optional, off by default; needs a Mac with Apple Intelligence on macOS 26 or later). Turn it on in Settings → "On-Device Writing Help". Then, in the editor:
   - "Suggest title & tags": the sparkles button in the editor toolbar, "More" → "Suggest Title & Tags…", the Entry menu, or type "/suggest" in the text. A small panel suggests a title, tags (each can be kept or skipped) and a one-line summary; nothing changes until "Apply".
   - "Go deeper": once an entry has a few sentences, a "Go deeper" button appears in the editor footer (also "More" → "Go Deeper…" or "/deeper"). It suggests up to three follow-up questions that can be inserted as a quote or heading.
   - "Ask your journal" (Entry menu, ⇧⌘A, or the command palette): ask a question about past entries. The app picks a few relevant entries on the Mac itself, gives short excerpts to Apple's on-device model, and shows the answer with links to the entries it used.
   All of this runs entirely on the Mac with Apple's Foundation Models framework. No text is sent anywhere. Hidden entries are never used while they are locked, and writing help is never offered for a hidden entry. On Macs without Apple Intelligence these controls are not shown, and Ask your journal explains why.
9. Voice memo transcripts (macOS 26 or later): next to a voice memo, click the transcript button (or, in the editor, "More" → "Transcribe Voice Memo…"). macOS asks for Speech Recognition permission. Recognition is forced on-device (requiresOnDeviceRecognition); if the Mac can't transcribe the language on-device, the option is not shown. "Insert into entry" adds the text to the entry, where it is encrypted with the rest of the entry.

Permissions and entitlements:
- Microphone (com.apple.security.device.audio-input): voice memos only.
- Speech Recognition (NSSpeechRecognitionUsageDescription): transcribing the user's own voice memos, on-device only, only when the user asks.
- User-selected files + app-scoped bookmarks: import/export/attachments and remembering the user's chosen backup folder.
- Print: printing a single entry.
- No network entitlements. The app makes no network requests.

Encryption: the app uses only encryption provided by Apple's operating system (CryptoKit, CommonCrypto) to protect the user's own data on their Mac. ITSAppUsesNonExemptEncryption is set to NO.

Data: the app collects no data. No analytics, advertising, tracking or third-party SDKs.

On-Device Writing Help is opt-in and off by default. It uses Apple's on-device Foundation Models only where the Mac supports Apple Intelligence; on other Macs the option is unavailable and its controls are hidden. Voice memo transcription uses Apple's Speech framework with on-device recognition required, so audio never leaves the Mac.
