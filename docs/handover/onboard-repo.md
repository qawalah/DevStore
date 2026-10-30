# Onboarding instructions for a Claude Code session

You're in a new, private app repo that the user just created. Its only
content is a `*-handover.zip` exported from a Claude chat. Turn it into a
DevStore app repo. DevStore lives at `qawalah/devstore`; read files from it
with the GitHub tools when you need them, starting with its templates.

## 1. Unpack
- Unzip the handover zip into the repo root, then delete the zip.
- If everything ended up inside one top-level folder, move it up to the root.
- Remove build outputs, APKs/EXEs, `local.properties`, keystores and any
  secrets that slipped in. If you find a secret, tell the user it was in the
  chat export so they can rotate it.
- Read `HANDOVER.md` fully before changing anything.

## 2. Decide the platform
From `HANDOVER.md` and the files: **Android** (has `gradlew` and an Android
module) or **Windows** (Python or Go; gui or service). If the repo has both an
Android app and a Windows companion, set up both.

## 3a. Android
1. Copy from DevStore `templates/app-repo/`: `.github/workflows/release.yml`,
   `CLAUDE.md` and `.gitignore`. Merge with existing files if any.
2. In the app module's `build.gradle(.kts)`:
   - remove any release `signingConfig` and `signingConfigs` that point at a
     keystore file (CI signs it). If `HANDOVER.md` says the app has its own
     key, tell the user its alias and point them to "Using an app's own key"
     in DevStore `docs/handover/README.md`, so installed copies keep updating,
   - **keep `applicationId` exactly as it is**,
   - bump `versionCode` by 1.
3. Make sure `gradlew` is executable: `git update-index --chmod=+x gradlew`.
4. If the module isn't called `app`, pass `module: <name>` under `with:` in
   the release workflow.
5. If an Android SDK is available, run `./gradlew assembleRelease`;
   otherwise rely on CI.

## 3b. Windows (Python, Go or C#/.NET)
1. Copy from DevStore `templates/windows-app-repo/`:
   `.github/workflows/release.yml`, `CLAUDE.md`, `.gitignore` and
   `devstore.json`, plus `requirements.txt` for a Python project that has
   none.
2. Fill in `devstore.json` as the template `CLAUDE.md` describes. `name` is
   permanent, lowercase-with-dashes, and becomes the exe name (for example
   `werd-server`). `language` is `python`, `go` or `dotnet`. `entry` is the
   `.py` file, the Go package, or the `.csproj`. Use `displayName` for a
   friendly Start-menu name.
3. If the app ships extra files next to its exe (for example an AI engine
   folder), use `include` for files in the repo, or a `prepare` script that
   downloads them into `$env:DEVSTORE_OUT`.
4. If it's a tray app that keeps running, set `"updateWhileRunning": true`.
5. Apply the template's code rules. Above all, keep data, settings and logs
   out of the install folder. Services must exit cleanly on Ctrl+C/SIGTERM.
   Mention any changes in your summary.
6. If `devstore.json` isn't at the repo root (for example in `server/`),
   pass `working-directory:` under `with:` in the release workflow.

## 3c. Both Android and Windows in one repo
Use DevStore `templates/app-repo-both/.github/workflows/release.yml` as the
only release workflow, with `working-directory` pointing at the Windows
part's folder. Do 3a for the Android part and steps 2–5 of 3b for the Windows
part, with one `CLAUDE.md` that has both sets of rules. Each part releases
when its own version is bumped. In Obtainium, filter the repo's releases
with `^android-`.

## 4. Finish
1. Keep `HANDOVER.md` in the repo.
2. Commit everything, with a message like "Onboard into DevStore", and push
   to `main`.
3. Watch the **Release** workflow run (GitHub Actions). If it fails, read
   the log, fix it and push again until it's green and a release exists.
   Common failures:
   - missing secrets (Android): ask the user to add them as described in
     DevStore `docs/handover/README.md` step 3,
   - "workflow not found": the DevStore Actions access setting isn't
     enabled; ask the user to enable it (README one-time step 2),
   - compile errors: fix them.
4. Tell the user the release tag and the next step: install it through
   Obtainium (Android) or add the repo in DevStore Manager (Windows).
