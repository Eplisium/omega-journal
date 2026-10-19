# Omega Journal — Privacy Policy

*Page source for https://unknownprojects.net/omega-journal/privacy. Effective date: **[set on publish]**.*

Omega Journal is a journal app for the Mac. It was built so that your writing stays yours. The short version: **we don't collect anything.** The app has no accounts, no analytics, no ads and no tracking, and it never connects to our servers or anyone else's.

## What the app stores, and where

Everything you create stays **on your Mac**, inside the app's own storage:

- your entries, titles, tags, moods, notebooks, templates, goals and settings;
- attachments you add (images, files, voice memos);
- automatic daily backups of the journal database.

**Encryption at rest.** Entry text, revision history, attachments and completed backups are encrypted on disk with AES-256-GCM (Apple CryptoKit). The key is kept in your Mac's Keychain and never leaves this Mac. To keep search and the sidebar fast, some details are stored **unencrypted** in the journal database: titles, tags, moods, dates and word counts. Anyone who can open your Mac user account and its files could read that metadata. Protecting your Mac account (password, FileVault) protects it.

## What we collect

Nothing. Omega Journal:

- has no user accounts or sign-in;
- contains no analytics, crash-reporting, advertising or tracking code;
- makes no network requests and has no network permission;
- does not share data with third parties, because we never receive it.

If you choose to share crash reports with Apple (a macOS setting), Apple may share them with developers in anonymous form under Apple's own privacy policy.

## Permissions the app may ask for

- **Microphone**: only when you record a voice memo for an entry. Recordings are encrypted and stored with that entry. You can turn this off at any time in System Settings → Privacy & Security → Microphone.
- **Touch ID or your Mac password**: used to unlock entries you have hidden. macOS handles this check itself. The app only learns whether it succeeded and never sees your fingerprint or password.
- **Files you pick**: when you import, export, attach or choose a backup folder, the app can access only the files and folders you select in the standard macOS open/save panel.
- **Notifications** (optional): local writing reminders scheduled on your Mac. They don't involve any server.

## Things that leave the app because you asked

Some actions put readable copies of your writing outside the app's encrypted storage, because that is what they are for:

- **Exports** (Markdown, JSON, HTML, PDF, print) are ordinary readable files saved where you choose. A passphrase-protected export option is available.
- **Opening an attachment** in another app creates a temporary decrypted copy, cleaned up when Omega Journal launches or quits.
- **An extra backup folder** you choose may be synced by another service (for example iCloud Drive or Dropbox). That service's own privacy terms apply.
- **Spotlight** (optional, off by default): if you turn it on, entry *titles* are added to your Mac's local Spotlight index so you can find them from Spotlight.

## Children

Omega Journal does not collect personal information from anyone, including children.

## Deleting your data

Delete the app, then delete its data: in Finder, open `~/Library/Containers/` and move the `com.eplisium.omega-journal` folder (shown as "Omega Journal") to the Trash. Backups you saved elsewhere and exports stay where you put them. To remove the encryption key, open Keychain Access, find the item named `com.omegajournal.encryption` and delete it. Do this only if you no longer need any encrypted backups.

## Changes

If this policy changes, the new version will be posted on this page with a new effective date. The app will never start collecting data without a clear notice in the app and on this page first.

## Contact

Questions about privacy: **support@unknownprojects.net** *(TO CONFIRM before publishing)*
Developer: Zach Gladfelter (Unknown Projects)
