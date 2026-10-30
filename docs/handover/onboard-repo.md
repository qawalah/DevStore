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
     keystore file (CI signs it),
   - **keep `applicationId` exactly as it is**,
   - bump `versionCode` by 1.
3. Make sure `gradlew` is executable: `git update-index --chmod=+x gradlew`.
4. If the module isn't called `app`, pass `module: <name>` under `with:` in
   the release workflow.
5. If an Android SDK is available, run `./gradlew assembleRelease`;
   otherwise rely on CI.

## 3b. Windows (Python or Go)
1. Copy from DevStore `templates/windows-app-repo/`:
   `.github/workflows/release.yml`, `CLAUDE.md`, `.gitignore`,
   `devstore.json`, plus `requirements.txt` if the project has none.
2. Fill in `devstore.json`:
   - `name`: lowercase-with-dashes, permanent, and the same as the exe the build makes (for example `werd-server`),
   - `language`: `python` or `go`,
   - `type`: `gui` or `service`,
   - `entry`: Python: the main `.py` file. Go: the main package (`.` or `./cmd/<name>`; `go.mod` must be next to `devstore.json`),
   - `version`: the current version, or `1.0.0`.
3. Apply the rules in the template `CLAUDE.md`. Above all, move data, settings
   and logs to `%ProgramData%\<name>\`, and make services exit cleanly on
   SIGINT, SIGTERM and SIGBREAK. Mention these changes in your summary.
4. If the project's code lives in a folder (for example `src/`), keep it and
   point `entry` at it. Only if `devstore.json` isn't at the repo root,
   pass `working-directory:` under `with:` in the release workflow.

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
