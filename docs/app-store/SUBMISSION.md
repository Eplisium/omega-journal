# Mac App Store submission checklist

Everything code-side is done in this repo. This is the account-side work, in order, then
the exact build commands. Team ID: **WWC5HJN6AL**. Bundle ID: **com.eplisium.omega-journal**.
Price: **$2.99** (paid up front, no in-app purchases).

Related files: [metadata.md](metadata.md), [review-notes.md](review-notes.md),
[privacy-policy.md](privacy-policy.md), [support.md](support.md), [screenshots.md](screenshots.md).

---

## 1. Business setup (App Store Connect → Business)

- [ ] **Paid Apps Agreement**: accept it (Business → Agreements). Free apps don't need it; a $2.99 app can't go on sale without it.
- [ ] **Banking**: add the bank account that receives payouts.
- [ ] **Tax forms**: complete the U.S. **W-9** (and the treaty forms it offers, if any).
- [ ] **EU Digital Services Act trader status**: App Store Connect → Business → *Digital Services Act*. Selling a paid app makes you a **trader**. You must publish an address, phone number and email on the EU storefronts (a business address or P.O. box is allowed). Without this the app is removed from EU storefronts.
- [ ] **App Store Small Business Program**: enroll at developer.apple.com/app-store/small-business-program. The commission drops from 30% to 15% while proceeds stay under $1M per year. Enroll before the first sale, because the rate applies from enrollment onward.

## 2. Certificates, App ID and profile (developer.apple.com → Certificates, IDs & Profiles)

You have **Apple Development** and **Developer ID Application** already. You need two more certificates, one App ID and one profile:

- [ ] **Apple Distribution** certificate: Certificates → **+** → *Apple Distribution* → upload a CSR (Keychain Access → Certificate Assistant → *Request a Certificate From a Certificate Authority…*, saved to disk) → download → double-click so it lands in the **login** keychain. Xcode → Settings → Accounts → *Manage Certificates* → **+** → *Apple Distribution* does the same in one step.
- [ ] **Mac Installer Distribution** certificate: Certificates → **+** → *Mac Installer Distribution* → same CSR flow. It signs the `.pkg`, and appears as `3rd Party Mac Developer Installer: …` in `security find-identity -v`.
- [ ] **Explicit App ID**: Identifiers → **+** → *App IDs* → *App* → Platform **macOS**, Bundle ID **Explicit** = `com.eplisium.omega-journal`, description "Omega Journal". Turn on no extra capabilities. Sandbox, microphone and file access are plain entitlements and need no capability. Keychain sharing for the app's own group comes with the App ID prefix.
- [ ] **Mac App Store provisioning profile**: Profiles → **+** → Distribution → **Mac App Store Connect** → App ID `com.eplisium.omega-journal` → tick your **Apple Distribution** certificate → name it `Omega Journal MAS` → download. Keep the `.provisionprofile` somewhere stable, e.g. `~/Developer/profiles/OmegaJournal_MAS.provisionprofile`.
- [ ] **App Store Connect API key** (for `--validate` / `--upload`): App Store Connect → Users and Access → Integrations → *App Store Connect API* → Team Keys → **+**, role **App Manager**. Note the **Key ID** and the **Issuer ID**. Download `AuthKey_<KEYID>.p8` (you can download it **only once**) to `~/.appstoreconnect/private_keys/`, then run `chmod 600` on it. Never commit it.

Check that the certificates are in the keychain:

```bash
security find-identity -v -p codesigning | grep -E "Apple Distribution|3rd Party Mac Developer Application"
security find-identity -v | grep -E "3rd Party Mac Developer Installer|Mac Installer Distribution"
```

## 3. Create the app record (App Store Connect → Apps → **+** → New App)

- [ ] Platform **macOS**, Name **Omega Journal**, primary language English (U.S.), Bundle ID `com.eplisium.omega-journal`, SKU `omega-journal-mac`, User Access: Full Access.
- [ ] **Pricing and Availability**: price **$2.99** (USD base price; let Apple set the other storefronts), all countries.
- [ ] **App Privacy**: Privacy Policy URL `https://unknownprojects.net/omega-journal/privacy` (publish [privacy-policy.md](privacy-policy.md) there first). Data collection → **"No, we do not collect data from this app"**, which shows as *Data Not Collected*.
- [ ] **App Information**: category, age rating and copyright from [metadata.md](metadata.md). Support URL `https://unknownprojects.net/omega-journal/support` (publish [support.md](support.md)).
- [ ] Version page: description, keywords, promotional text, screenshots ([screenshots.md](screenshots.md)), and review notes ([review-notes.md](review-notes.md)).

## 4. Build and upload

Bump `VERSION` for a new marketing version. The build number defaults to the git commit
count on `main`, so every upload from a newer commit is higher. Override it with
`OMEGA_JOURNAL_BUILD_NUMBER=<n>` if you ever need to re-upload the same commit.

```bash
cd ~/OmegaJournal
git checkout main && git pull
swift build && swift test --no-parallel

# 1) Smoke-test the sandboxed bundle (no certificates needed; QA bundle id, never your real journal)
scripts/make_mas.sh --dev

# 2) Real package: signs with Apple Distribution, embeds the profile, builds the .pkg
export OMEGA_JOURNAL_MAS_PROFILE=~/Developer/profiles/OmegaJournal_MAS.provisionprofile
scripts/make_mas.sh
#   → dist/OmegaJournal-<version>-<build>.pkg

# 3) Ask App Store Connect to validate it, then upload (TestFlight)
export ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
scripts/make_mas.sh --validate
scripts/make_mas.sh --upload
```

If something is missing, `make_mas.sh` stops before building and lists exactly what to create.
Signing identities are auto-detected. To pick specific ones, set
`OMEGA_JOURNAL_MAS_APP_IDENTITY` / `OMEGA_JOURNAL_MAS_INSTALLER_IDENTITY`.

The build appears under **TestFlight** after processing, usually within 5–30 minutes. If processing
fails, Apple emails the reason (missing icon size, SDK, entitlement mismatch…).

The direct-download DMG is unchanged in spirit:
`OMEGA_JOURNAL_SIGN_IDENTITY="Developer ID Application: …" OMEGA_JOURNAL_NOTARY_PROFILE=omega-notary scripts/make_release.sh`.
It now carries the microphone entitlement, so voice memos work in the notarized build.

## 5. TestFlight test plan

> ⚠️ **Do the upgrade test on a spare macOS user account first.** The TestFlight build uses
> the production bundle id. The first time it launches under a user account, macOS runs
> the container migration **once** and moves that user's `~/Library/Application Support/OmegaJournal`
> into the sandbox container. Do it on a throwaway account to rehearse before your own data.

Setup: System Settings → Users & Groups → add a standard user "OJ Test". Log in to it, sign in to TestFlight with your Apple ID (the internal tester).

**A. Fresh install (no previous data)**
- [ ] Install from TestFlight, launch: onboarding appears, the window opens quickly, CPU drops to ~0%.
- [ ] Write an entry, add a tag and mood, quit, relaunch: the entry is still there.
- [ ] Record a voice memo: macOS asks for microphone access once; playback works.
- [ ] Attach a file through the attach button (the open panel works in the sandbox).
- [ ] Export JSON/Markdown/PDF to Desktop through the save panel; import a Markdown folder.
- [ ] Backups: choose a backup folder, quit, relaunch, run a backup again. The folder is remembered (security-scoped bookmark).
- [ ] Hide an entry, lock, unlock with Touch ID/password.
- [ ] Print an entry (print panel opens).
- [ ] Settings → About shows the support and privacy links, with no GitHub links (App Store channel).

**B. Upgrade from the 1.0.2 DMG (the important one)**
- [ ] On the spare account, install **Omega-Journal-1.0.2.dmg**. Create 3 entries (one hidden, one with a voice memo or image attachment) and change a couple of settings (theme, editor font). Quit.
- [ ] Note `~/Library/Application Support/OmegaJournal/` exists.
- [ ] Delete `/Applications/Omega Journal.app` (the DMG copy), then install the TestFlight build. A same-bundle-id App Store app should not sit beside a DMG copy.
- [ ] Launch: entries, tags, the hidden entry (after unlock), attachments and the settings all appear **without** re-entering anything.
- [ ] `~/Library/Application Support/OmegaJournal` is gone and the data now lives in `~/Library/Containers/com.eplisium.omega-journal/Data/Library/Application Support/OmegaJournal/`.
- [ ] No Keychain password prompt loop: the encryption key is read from the login keychain and copied to the app's keychain group.
- [ ] Fallback: on another fresh spare account where migration had nothing to move, "Import existing journal…" (Settings) can pick a copied `OmegaJournal` folder.
- [ ] Reinstall the 1.0.2/1.1.0 DMG build afterwards and launch it: it finds the container database instead of starting empty, so data doesn't split.

**C. Before release**
- [ ] Test on Apple silicon and, if available, an Intel Mac (the build is universal).
- [ ] Test on the oldest supported macOS (14 Sonoma) if you can borrow a machine or VM.

## 6. Submit

- [ ] Select the processed build on the version page, answer **Export Compliance** (should be pre-answered because `ITSAppUsesNonExemptEncryption = NO` is in Info.plist; see [metadata.md](metadata.md)).
- [ ] Paste [review-notes.md](review-notes.md) into *App Review Information → Notes*. No demo account is needed (sign-in not required).
- [ ] *Version Release*: "Manually release this version" so you control launch day.
- [ ] **Add for Review** → **Submit**.

## How the pieces fit (reference)

| File | Used by | Purpose |
|---|---|---|
| `VERSION` | all scripts | marketing version (CFBundleShortVersionString) |
| `packaging/Info.plist.template` | all scripts | every Info.plist key; `OJDistributionChannel` = `direct`/`appstore` |
| `packaging/OmegaJournal-Direct.entitlements` | `build_app.sh`, `make_release.sh` | microphone under hardened runtime, not sandboxed |
| `packaging/OmegaJournal-AppStore.entitlements` | `make_mas.sh` | sandbox, user-selected files, bookmarks, microphone, print, app id, keychain group |
| `packaging/PrivacyInfo.xcprivacy` | all scripts | privacy manifest (UserDefaults CA92.1, file timestamps C617.1/3B52.1) |
| `packaging/container-migration.plist` | `make_mas.sh` | moves the DMG-era journal + prefs into the container on first sandboxed launch |

Container migration was verified live with a QA bundle id and fake data. The manifest format is the
one Apple documents, and macOS moved both a folder and a prefs file into a fresh container.
The app has to be launched through LaunchServices (`open`, Finder, Dock) for this to work. When
the binary is started from a shell, macOS attributes the move to the shell, and App Data
protection blocks the folder copy. Real users always launch through LaunchServices.
