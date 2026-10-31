---
name: devstore-handover
description: Use when the user says "hand over to DevStore", "move this to a repo", "export for Claude Code" or "package this app for DevStore". Packages the app built in this chat as a handover zip (app-name-handover.zip) with a HANDOVER.md, ready for the devstore-onboard skill in Claude Code.
---

# DevStore handover (chat side)

The user is moving the app built in this conversation into its own GitHub
repo, where Claude Code will develop and release it through DevStore.
Package it now, without asking questions unless the app name or platform is
truly unclear.

## 1. The zip
Create **one zip file** named `<app-name>-handover.zip` (lowercase with
dashes) containing the **complete, latest, buildable project**, exactly as it
should be committed: every source file, resource, asset and config file, with
the latest version of each file from this conversation.
- **Android:** include `settings.gradle(.kts)`, all `build.gradle(.kts)`
  files, `gradle.properties`, `gradlew`, `gradlew.bat` and `gradle/wrapper/`
  (generate the wrapper if it's missing).
- **Python:** include `requirements.txt` listing every third-party
  dependency.
- **Go:** include `go.mod` and `go.sum`.
- **Don't include** build outputs (`build/`, `dist/`, `.gradle/`,
  `__pycache__/`), APKs or EXEs, keystores (`*.jks`, `*.keystore`),
  passwords, API keys or `local.properties`.
- Put the project at the **root of the zip**, not inside an extra folder.

## 2. HANDOVER.md (at the root of the zip)
- **What the app does**, in a few sentences, plus its main features.
- **Platform and type:** Android app, Windows window/tray app, Windows
  background service, or a server for the NAS (Docker). List every part.
- **Identity:** Android: exact `applicationId`, current `versionCode` and
  `versionName`, and whether it already has its own signing key (alias
  only). Python/Go: entry file or package, current version, exe name.
- **How it's built and run**, including any manual steps.
- **Where it stores data** and any external services, servers or ports.
- **Secrets it needs** (names only, never values) and how they're provided
  today.
- **Known bugs, unfinished work and next ideas** from this conversation.
- **Important decisions** and why, so they aren't undone later.

## 3. Hand back
Give the zip as a downloadable file, list its top-level contents, and end
with these next steps for the user:

1. Open a Claude Code session on `qawalah/devstore` (Claude app → Code).
2. Attach this zip and send: `/devstore-onboard <app-name>`

That session creates the repo, sets it up and pushes the first release.
