# Security policy

Omega Journal stores private writing, so we take reports seriously.

## Reporting a vulnerability

Please **do not open a public issue** for anything that could expose journal
content, encryption keys, or hidden entries.

Instead, use GitHub's private
[**Report a vulnerability**](https://github.com/Eplisium/omega-journal/security/advisories/new)
form. Include the macOS version, the app version or commit, and steps to
reproduce. You'll get an acknowledgement within a few days.

## Scope

In scope: entry/attachment encryption, Keychain key handling, hidden-entry
locking, backups and restore, import/export, and anything that leaks content
to disk, logs, or Spotlight unexpectedly.

The README's "Privacy and security" section documents known boundaries (for
example, titles, tags and moods are stored as plain metadata). Reports that
improve on those boundaries are welcome as normal issues or PRs.

## Supported versions

Fixes land on `main` and ship in the next release.
