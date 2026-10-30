# Prompt to paste into the old Claude chat

Copy everything below the line into the Claude chat where the app was
developed.

---

I'm moving this project into a GitHub repo, where it will be developed with
Claude Code and released automatically. Please package it for handover:

1. Create **one zip file** named `<app-name>-handover.zip` containing the
   **complete, latest, buildable project**, exactly as it should be
   committed: every source file, resource, asset and config file, with the
   latest version of each file from this conversation.
   - **Android projects:** include `settings.gradle(.kts)`, all
     `build.gradle(.kts)` files, `gradle.properties`, `gradlew`, `gradlew.bat`
     and `gradle/wrapper/` (generate the wrapper if it's missing).
   - **Python projects:** include `requirements.txt` listing every
     third-party dependency.
   - **Go projects:** include `go.mod` and `go.sum`, and tell me the main
     package folder and the exe name.
   - **Don't include** build outputs (`build/`, `dist/`, `.gradle/`,
     `__pycache__/`), APKs or EXEs, keystores (`*.jks`, `*.keystore`),
     passwords, API keys or `local.properties`.
   - Put the project at the **root of the zip**, not inside an extra
     top-level folder.
2. Add a file `HANDOVER.md` at the root of the zip with:
   - **What the app does**, in a few sentences, plus its main features.
   - **Platform and type:** Android app, Windows window/tray app, or
     Windows background service. Say which if there are several parts.
   - **Identity:** for Android, the exact `applicationId`, current
     `versionCode` and `versionName`; for Python, the entry file and current
     version.
   - **How it's built and run**, including any manual steps or special setup.
   - **Where it stores data** (files, databases, settings) and any external
     services, servers or ports it talks to.
   - **Secrets it needs** (names only, never values), and how they're
     provided today.
   - **Known bugs, unfinished work and next ideas** from this conversation.
   - **Important decisions** we made and why, so they aren't undone later.
3. Give me the zip as a downloadable file, and list its top-level contents.
