# DevStore: Android and Windows Auto-Update Pipeline (Design)

Date: 2026-10-28
Status: Android part approved. Windows part (§8–§12) awaiting review.

## 1. Goal

When an app I'm developing with Claude gets a new version, it installs itself
on my devices automatically: Android apps on my phone (Part A, §2–§7), and
Python apps and services on my Windows PC (Part B, §8–§12). I don't download
or install anything by hand.

### What the user said
- It's a personal "app store" for apps I develop with Claude. I'm the only user.
- My phone is Android. Phase 1 is Android only.
- Most apps were developed in Claude **chat**. APKs are downloaded and
  installed by hand today, and Android already treats each new APK as an
  update of the existing app.
- Publishing to GitHub (private) is fine. A private local (home Wi-Fi) channel
  is nice to have but not required.
- Windows: one PC for now. Apps are Python, both window/tray apps and
  always-on background services. The user chose "one updater on the PC"
  over self-updating apps.
- Docker: later, not in this spec.

### Assumptions
- All repos live under the personal GitHub account `qawalah`. It's a personal
  account, not an org, so there are no shared org-level secrets.
- From now on, apps are developed in **Claude Code** sessions attached to each
  app's repo. Claude chat can't reliably push to GitHub.
- Apps are standard Gradle Android projects that include the Gradle wrapper
  (`gradlew`).

### Success criteria
1. Pushing a version bump to an app repo's `main` branch produces a signed APK
   on a GitHub Release within about 15 minutes, with no manual steps.
2. Obtainium on the phone detects and installs that release without me opening
   a browser or file manager.
3. An existing chat-developed app can be moved into this pipeline by following
   one handover document, in under 30 minutes per app.
4. Bumping `version` in a Windows app repo results, within about 25 minutes,
   in the new version running on the PC. A service that fails to start rolls
   back by itself.

## 2. Architecture

```
Claude Code session ──push──▶ app repo (private, qawalah/<app>)
                                  │ push to main
                                  ▼
                       GitHub Actions: caller workflow
                                  │ uses
                                  ▼
            qawalah/devstore reusable workflow (android-release.yml)
              build → sign → read version → tag → GitHub Release (APK)
                                  │
                                  ▼
                    Obtainium on phone (polls releases,
                    installs updates in the background)
```

There's no custom server, app or database. DevStore is a repo of shared
pipeline pieces plus documentation.

## 3. Components

### 3.1 Reusable workflow: `.github/workflows/android-release.yml` (in DevStore)
A `workflow_call` workflow that app repos call. Steps:
1. Check out the caller repo and set up JDK 17 and the Android SDK.
2. `./gradlew assembleRelease`. The app's Gradle files carry **no** release
   signing config, so the output is an unsigned release APK.
3. `zipalign` and `apksigner sign` it with the shared DevStore key, decoded
   from secrets.
4. Read `versionName` and `versionCode` from the signed APK using
   `aapt2 dump badging`.
5. Compute tag `android-v<versionName>+<versionCode>`. The platform prefix
   lets one repo hold both an Android app and its Windows companion without
   tag collisions; in that case, set Obtainium's release filter to
   `^android-`. **If the tag already exists,
   stop successfully without a new release.** This makes reruns safe, and a
   push without a version bump is only a build check.
6. Create the tag and a GitHub Release with asset `<repo>-<versionName>.apk`.

Inputs (all optional): `module` (default `app`), `java-version` (default `17`).
Required secrets: `DEVSTORE_KEYSTORE_B64`, `DEVSTORE_KEYSTORE_PASSWORD`.
The key alias is fixed as `devstore`, and the key password equals the
keystore password, so there are only two secrets per repo.

The workflow needs `contents: write` permission to create tags and releases.

**One-time setting:** DevStore → Settings → Actions → General → Access →
"Accessible from repositories owned by the user 'qawalah'". Without it,
private app repos can't call the reusable workflow.

### 3.2 Caller template: `templates/app-repo/.github/workflows/release.yml`
About 10 lines. It triggers on `push` to `main` and on `workflow_dispatch`,
then calls `qawalah/devstore/.github/workflows/android-release.yml@main` with
the secrets passed through. It's copied unchanged into every app repo.

### 3.3 App repo rules: `templates/app-repo/CLAUDE.md`
Instructions that every Claude Code session in an app repo reads:
- Never change `applicationId`.
- Bump `versionCode` (+1) and `versionName` for every change the user should
  receive. No bump means no release.
- Don't add a release `signingConfig`; CI signs the APK.
- Keep `gradlew` and the wrapper files committed.
- Commit and push to `main` when a change is done. That push *is* the
  release.
- Before pushing, run `./gradlew assembleRelease` locally if the environment
  allows it.

### 3.4 Signing key script: `scripts/create-signing-key.sh`
Runs once, anywhere with a JDK (for example a Claude Code session).
- Creates `devstore.jks` with alias `devstore`, RSA 4096, valid for 30 years.
- Prints the base64 value and the password to paste as the two repo secrets.
- Tells the user to save the `.jks` file and password in a password manager
  or cloud backup. **If the key is lost, every app must be uninstalled and
  reinstalled.**
- Never commits the key. `*.jks` and `*.keystore` are in `.gitignore`.

### 3.5 Handover guide: `docs/handover/README.md` plus a chat prompt
Moves an existing chat-developed app into the pipeline:

1. **In the existing Claude chat**, paste the prompt from
   `docs/handover/chat-export-prompt.md`. It asks the chat to produce **one
   zip** of the complete, buildable project: Gradle wrapper, all source and
   resources, current `applicationId`, `versionCode` and `versionName`, and a
   `HANDOVER.md` summarizing the app, its features, known issues and pending
   work from the chat. It must not include build outputs or keystores.
2. **On GitHub (web or app):** create a private repo `qawalah/<app-name>`
   and upload the single zip with "Add file → Upload files".
3. **Add the two secrets** (Settings → Secrets and variables → Actions), using
   the same values for every repo.
4. **Start a Claude Code session on the new repo** and say: "Follow the
   DevStore onboarding in `qawalah/devstore/docs/handover/onboard-repo.md`."
   That session:
   - unzips the project to the repo root and deletes the zip,
   - adds the caller workflow, `CLAUDE.md`, `HANDOVER.md` and `.gitignore`,
   - removes any release `signingConfig`,
   - bumps `versionCode`,
   - pushes. The first release is created automatically.
5. **On the phone, one time per app:** uninstall the old copy, then add the
   repo in Obtainium and install from there. This is unavoidable because the
   old APK was signed with a different key, and Obtainium must be the app's
   installer to update it silently. If the app holds data you care about,
   export it first.

**Windows apps** use the same steps 1, 2 and 4, without the secrets in
step 3. Onboarding adds `devstore.json` and the Windows template instead.
In place of step 5, run `Add-DevStoreApp.ps1 -Repo qawalah/<app>` on the PC
once (§10.3).

`docs/handover/onboard-repo.md` holds the step-by-step instructions for the
step-4 session, so they live in one place.

### 3.6 Phone setup guide: `docs/phone-setup.md`
- Install Obtainium (from its GitHub releases or F-Droid).
- Create a fine-grained GitHub personal access token: read-only
  **Contents** on all `qawalah` repos (or only the selected app repos). Enter
  it in Obtainium → Settings → GitHub token so private repos work.
- Add each app by its repo URL and enable background updates.
- Turn on "Install unknown apps" for Obtainium.
- Note on Google's developer verification rules: already enforced in Brazil,
  Indonesia, Singapore and Thailand, with worldwide enforcement planned for
  2027. If they apply on your phone, enable the advanced sideloading option
  once in Developer Options; there's a one-time 24-hour wait. Revisit before
  2027.

### 3.7 Pipeline self-test: `samples/hello-android/` plus `.github/workflows/self-test.yml`
A minimal Android app inside DevStore. On every push to DevStore, the
self-test runs the build, sign and version-read steps against it, with a
throwaway key generated in CI and no release published. This catches
breakage in the shared workflow before it reaches app repos.

## 4. Error handling

| Failure | Result | Recovery |
|---|---|---|
| Build or compile error | Workflow fails and GitHub emails me. No release, so the phone is untouched. | Ask Claude Code to fix it from the Actions log. |
| `versionCode` not bumped | Tag exists, so the workflow passes with "no new version". | Bump and push again. |
| Missing or wrong secrets | Signing step fails with a clear message naming the secret. | Add or fix the repo secrets. |
| Reusable workflow access not enabled | Caller fails with "workflow not found". | Enable the DevStore Actions access setting (§3.1). |
| Lost signing key | Updates can't be signed with the old key. | Prevented by backups. Otherwise new key, then reinstall all apps. |
| Obtainium can't see a private repo | No update shown. | Check token expiry and scope. |

## 5. Testing
- Self-test workflow (§3.7) on every DevStore push.
- End-to-end check: create a `hello` app repo from the template, push a
  bump, confirm a Release appears, and confirm Obtainium installs it. Push a
  second bump and confirm a silent update.
- Handover check: migrate one real chat-developed app using only the docs.

## 6. Out of scope (Phase 1)
- Local/home Wi-Fi channel (nice to have, later). Obtainium can track a plain
  web link, so a local folder served over HTTP can be added as a second source
  without changing this design.
- Docker (later, same pattern: GHCR plus a maintained Watchtower fork).
  Windows is covered in Part B.
- Dashboard across apps and devices.
- App bundles (AAB), Play Store, multiple build flavors.

## 7. Repo layout

```
.github/workflows/android-release.yml   reusable: build/sign/release APK
.github/workflows/windows-release.yml   reusable: PyInstaller build/release zip (§9)
.github/workflows/self-test.yml         validates both on samples/ (+ Pester tests)
templates/app-repo/                     Android app repo files
templates/windows-app-repo/             Windows app repo files (§9.2)
scripts/create-signing-key.sh
windows/agent/                          PC updater (§10)
samples/hello-android/
samples/hello-windows-gui/
samples/hello-windows-service/
docs/phone-setup.md
docs/windows-setup.md
docs/handover/README.md                 covers Android and Windows apps
docs/handover/chat-export-prompt.md
docs/handover/onboard-repo.md
README.md
```

---

# Part B: Windows (Python apps and services)

## 8. Architecture

```
Claude Code session ──push──▶ app repo (private, qawalah/<app>)
                                  │ push to main
                                  ▼
          qawalah/devstore reusable workflow (windows-release.yml)
          on windows-latest: PyInstaller → zip + sha256 → GitHub Release
                                  │
                                  ▼
       Windows PC: "DevStore Updater" scheduled task (PowerShell, SYSTEM)
       every 10 min: check releases → download → verify → swap → restart
                     → health check → roll back if unhealthy
```

The app's code never contains update logic. The PC doesn't need Python
installed, because each release is a self-contained PyInstaller build.

## 9. Build side

### 9.1 Reusable workflow: `.github/workflows/windows-release.yml`
A `workflow_call` workflow running on `windows-latest`:
1. Check out, then `actions/setup-python` (input `python-version`, default
   `3.12`).
2. `pip install -r requirements.txt pyinstaller`.
3. Read `devstore.json` from the repo root (§9.2).
4. Run PyInstaller in **onedir** mode, not onefile: it starts faster and
   swaps cleanly. GUI apps use `--noconsole`. The build includes
   `devstore.json` so the PC knows the app's type and exe name.
5. Zip as `<name>-<version>-win-x64.zip`, plus a `.sha256` file.
6. Tag `windows-v<version>`. **If the tag exists, stop successfully**, the
   same rule as Android.
7. Create a GitHub Release with both files.

No secrets are needed: there's no code signing in this phase (see §12).
GitHub counts Windows build minutes at 2x, so a 5-minute build uses 10 of the
2,000 free monthly minutes.

### 9.2 App repo template: `templates/windows-app-repo/`
- `.github/workflows/release.yml`: the caller, about 10 lines.
- `devstore.json`, the single source of truth for the app:
  ```json
  {
    "name": "my-app",
    "type": "gui",
    "entry": "src/main.py",
    "version": "1.0.0"
  }
  ```
  `type` is `gui` or `service`. `version` is semver, and bumping it is the
  release trigger.
- `CLAUDE.md` rules:
  - Bump `version` in `devstore.json` for every change the user should
    receive.
  - **Store data, settings and logs in `%ProgramData%\<name>\`, never next
    to the exe.** The install folder is replaced on every update.
  - Services must shut down cleanly on Ctrl+C/SIGTERM within 20 seconds and
    run in the foreground (no daemonizing).
  - List every dependency in `requirements.txt`.

## 10. PC side: `windows/agent/`

### 10.1 Folder layout on the PC
```
C:\DevStore\
  config.json                  list of apps: { "repo": "qawalah/x" }
  state.json                   installed version per app, bad versions
  token.dat                    GitHub token, DPAPI-encrypted (machine scope)
  logs\updater-YYYY-MM.log
  tools\winsw.exe
  apps\<name>\
    versions\<version>\        extracted builds (current + 1 previous kept)
    current  →  junction to the active versions\<version>\
    service\<name>.xml         WinSW config (services only)
```
Everything the user runs points at `apps\<name>\current\`. An update simply
repoints the junction, so a rollback is the same operation in reverse.

### 10.2 `Install-DevStoreAgent.ps1` (run once, as admin)
- Creates `C:\DevStore\` and restricts its permissions to SYSTEM and
  Administrators.
- Asks for a fine-grained GitHub token (read-only **Contents**, the same kind
  as the phone's) and stores it with DPAPI.
- Downloads a pinned WinSW release and verifies its hash.
- Registers the scheduled task **"DevStore Updater"**: runs as SYSTEM at
  startup and every 10 minutes.
- Is safe to re-run; it upgrades the agent in place.

### 10.3 `Add-DevStoreApp.ps1 -Repo qawalah/<app>` / `Remove-DevStoreApp.ps1`
Adds or removes an entry in `config.json`, then triggers an immediate run.
Removing an app stops and uninstalls its service and deletes its shortcut.
`-KeepData` is the default, so `%ProgramData%\<name>` stays.

### 10.4 `DevStoreUpdater.ps1` (each run)
- Takes a named mutex, so overlapping runs exit immediately.
- For each app in `config.json`:
  1. Asks the GitHub API for the newest release whose tag starts with
     `windows-v`. It skips versions marked bad in `state.json` and does
     nothing if the newest one is already installed.
  2. Downloads the zip and `.sha256` through the API asset endpoint, which
     works for private repos, and verifies the hash.
  3. Extracts the build to `versions\<version>\` and reads its
     `devstore.json` for the type and exe.
  4. **First install:**
     - Service: writes the WinSW XML (exe = `current\<exe>`, auto-start,
       restart on crash), installs it as `devstore-<name>` and starts it.
     - GUI: creates a Start Menu shortcut in
       `ProgramData\...\Start Menu\Programs\DevStore\` pointing at
       `current\<exe>`.
  5. **Update, service:** stop the service (30 s timeout), repoint
     `current`, start it, then check it is still `Running` after 30 s.
     If not: repoint back, start the old version, mark the new version bad,
     and log it.
  6. **Update, GUI:** if any process is running from that app's folder,
     **defer** to the next run, so nothing is killed while you're using it.
     Otherwise, repoint `current`. The next launch opens the new version.
  7. Deletes versions older than current and one previous.
- Writes one log line per action. Errors in one app never stop the others.

## 11. Error handling (Windows)

| Failure | Result | Recovery |
|---|---|---|
| Build error | Workflow fails, GitHub emails me, PC untouched. | Fix via Claude Code. |
| `version` not bumped | Tag exists, so no release. | Bump and push. |
| Download or hash mismatch | Version skipped this run; retried next run. | Automatic. |
| New service version won't stay running | Rolled back to the previous version; version marked bad and not retried. | Fix and release a higher version. |
| GUI app open during update | Update deferred. | Applies after the app is closed. |
| Token expired or wrong scope | All checks fail; logged clearly. | Re-run the installer with a new token. |
| PC off | Nothing happens. | Catches up at the next startup. |

## 12. Testing, scope and limits (Windows)

**Testing:**
- **Pester unit tests** for the updater's decision logic (picking a release,
  version comparison, bad-version skipping, state read/write), run on
  `windows-latest` in `self-test.yml`.
- **Self-test build** of `samples/hello-windows-gui` and
  `samples/hello-windows-service` through `windows-release.yml`, without
  publishing.
- **End-to-end on the PC:** install the agent, add the sample service, then
  release v1 → v2 (update) → v3 that crashes on start (confirm rollback to
  v2). Add the sample GUI and confirm an update is deferred while it's open
  and applied after it's closed.

**Out of scope:**
- Code signing. Unsigned PyInstaller exes can trigger SmartScreen or
  antivirus false positives. The updater runs as SYSTEM, so SmartScreen
  doesn't block updates, but Defender may occasionally flag a build.
  Revisit if it happens.
- Multiple PCs (the design works on several PCs, but only one is tested).
- Docker, a dashboard, and update notifications (toasts).

## 13. DevStore Manager (Windows UI)

Added at the user's request ("an app with UI for the Windows side"). It's a
desktop window for seeing and controlling the updater. It **doesn't replace**
the scheduled task, which keeps doing the updating even when the Manager is
closed.

**Tech:** Python + tkinter/ttk (standard library, small PyInstaller build).
The code is split into `model.py` (pure logic, unit-tested), `actions.py`
(runs elevated commands) and `ui.py` (widgets only).

**Delivery (dogfooding):** the Manager lives in `windows/manager/` with its
own `devstore.json` (`type: gui`). It's built by the same
`windows-release.yml` (new input `working-directory`) from the DevStore repo
itself, and installed and updated by the updater like any other app.
`Install-DevStoreAgent.ps1` adds `qawalah/devstore` to `config.json`
automatically. Its shortcut is "DevStore Manager". Like any GUI app, its own
updates wait until it's closed.

**What it shows** (re-read from disk every 15 s, plus a Refresh button):
- One row per app: name, type, installed version, latest available version,
  status, last checked. Status is one of: Up to date, Update pending
  (waiting for the app to close), Running/Stopped (services), Failed (rolled
  back: version X marked bad), or Not installed yet.
- Footer: the updater task's last run time and result, plus the next run.
- Selected app details: the last 50 log lines for that app.

**Actions:**
- **Check now** runs the updater task immediately.
- **Add app…** asks for a repo (`qawalah/<app>`).
- **Remove** asks for confirmation; data is kept.
- **Launch** (GUI apps) and **Start/Stop/Restart** (services).
- **Open data folder**.

Actions that change the system (Check now, Add, Remove, Start/Stop/Restart)
go through one Windows admin (UAC) prompt each, by running the agent scripts
elevated. The Manager itself runs as a normal user, with **read-only** access
to `config.json`, `state.json` and logs, and **no** access to `token.dat`.

**State contract with the updater** (so the Manager never calls GitHub
itself and needs no token): after each run, `state.json` holds, per app:
`installed`, `previous`, `latest`, `type`, `exe`, `status`, `lastChecked`,
`lastError`, `bad` (list). At the top level it holds `lastRun` and
`lastRunResult`.

**Permissions** (set by the installer): `C:\DevStore` gives Users read and
execute access, which they need to run GUI apps and for the Manager to read
state. `token.dat` has inheritance removed and is limited to SYSTEM and
Administrators.

**Tests:** pytest for `model.py`: building rows from state, config and
service info, status mapping, log filtering, and tolerating missing or
corrupt `state.json`. pytest for `actions.py`, checking the exact
command lines with `subprocess` mocked. The UI is checked by hand on the PC.

## 14. Go apps (added after the first Windows design)

`windows-release.yml` also builds **Go** apps. `devstore.json` gets an
optional `"language": "python" | "go"` (default `python`). For Go, `entry` is
the package to build (default `.`) and `go.mod` must sit next to
`devstore.json`. The build is `CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go
build -trimpath -ldflags "-s -w -X main.version=<version>"` into
`<name>.exe` (plus `-H=windowsgui` for `gui` apps). The result is packaged,
hashed and released exactly like a Python build, so the PC-side updater and
the Manager need no change. Covered by `samples/hello-windows-go` in the
self-test.
