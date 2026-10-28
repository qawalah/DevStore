# DevStore Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a version is bumped, Android apps update on the phone (via
Obtainium) and Python apps and services update on the Windows PC (via a
scheduled updater with a tkinter Manager UI), all from private GitHub
Releases.

**Architecture:** DevStore holds reusable GitHub Actions workflows (Android
build/sign/release, Windows PyInstaller build/release), templates for app
repos, a PowerShell updater agent for Windows, and the DevStore Manager UI.
The Manager is itself released and updated through the Windows pipeline.

**Tech Stack:** GitHub Actions; Gradle/AGP 8.7 + apksigner; Python 3.12 +
PyInstaller 6 + tkinter; Windows PowerShell 5.1-compatible scripts + Pester
5; WinSW 2.12.0.

**Spec:** `docs/superpowers/specs/2026-10-28-devstore-pipeline-design.md`

## Global Constraints
- Tags: Android `android-v<versionName>+<versionCode>`; Windows `windows-v<version>`. If the tag exists, publish nothing and succeed.
- Android secrets: `DEVSTORE_KEYSTORE_B64` and `DEVSTORE_KEYSTORE_PASSWORD`; alias `devstore`; key password = keystore password.
- Windows asset names: `<name>-<version>-win-x64.zip` plus `<name>-<version>-win-x64.zip.sha256`.
- PC root `C:\DevStore`; scheduled task `DevStore Updater` (SYSTEM, at startup and every 10 min); services named `devstore-<name>`; keep current + 1 previous version.
- Service health check: still `Running` 30 s after start; stop timeout 30 s.
- Agent scripts must run on Windows PowerShell 5.1 (no `??`, no ternary, no `-AsHashtable`).
- Never commit keys: `*.jks`, `*.keystore` go in `.gitignore`.
- The Manager never calls GitHub and never reads `token.dat`.

## Review Focus
1. `state.json` missing, empty or half-written → the updater and Manager treat it as empty state; the updater rewrites it atomically. (Task 4, Task 7 tests)
2. Releases including drafts, prereleases, `android-` tags or non-semver tags → only the highest `windows-v` semver release is picked. (Task 4 test)
3. A version marked bad, followed by a newer good version → the newer one installs; the bad one is never retried. (Task 4 test)
4. A repo whose release lacks the `.sha256` asset or has a mismatched hash → the update is skipped with an error in `lastError`, and the installed version is untouched. (Task 5 test)
5. GUI app running from `apps\<name>\` → status `pending`, no swap. (Task 5 test)

---

### Task 1: Repo basics
**Files:** Create `.gitignore`, `README.md` (overwrite the stub).
- [ ] `.gitignore`: `*.jks`, `*.keystore`, `__pycache__/`, `.pytest_cache/`, `build/`, `dist/`, `*.spec`, `.gradle/`, `local.properties`, `*.apk`.
- [ ] README: what DevStore is, plus links to the setup docs from Task 8.
- [ ] Commit.

### Task 2: Android pipeline
**Files:** Create `.github/workflows/android-release.yml`,
`templates/app-repo/{.github/workflows/release.yml,CLAUDE.md,.gitignore}`,
`scripts/create-signing-key.sh`, `samples/hello-android/` (Gradle wrapper
8.14.3, AGP 8.7.3, Java only, compileSdk 35, minSdk 24, `applicationId
dev.qawalah.hello`).

**Interfaces:** the reusable workflow takes inputs `working-directory`
(default `.`), `module` (`app`), `java-version` (`17`) and `publish` (bool,
`true`). Secrets come from the caller via `secrets: inherit`. When
`publish: false` and the secrets are absent, it generates a throwaway key.
- [ ] Workflow steps per spec §3.1, using the newest `$ANDROID_HOME/build-tools/*` for zipalign, apksigner and aapt2. Missing secrets with `publish: true` → fail with `::error::Missing secret DEVSTORE_KEYSTORE_B64`.
- [ ] `create-signing-key.sh [out.jks]`: prompts for a password (min 8 chars) and runs `keytool -genkeypair -alias devstore -keyalg RSA -keysize 4096 -validity 10950`. It prints the base64 value and backup instructions, and refuses to overwrite an existing file.
- [ ] Verify: `bash scripts/create-signing-key.sh` in a temp directory produces a JKS that `keytool -list` shows with alias `devstore`.
- [ ] Commit.

### Task 3: Windows build pipeline
**Files:** Create `.github/workflows/windows-release.yml`,
`templates/windows-app-repo/{.github/workflows/release.yml,CLAUDE.md,devstore.json,requirements.txt,.gitignore}`,
`samples/hello-windows-gui/` (tkinter window showing its version),
`samples/hello-windows-service/` (loop that writes a heartbeat to
`%ProgramData%\hello-windows-service\heartbeat.log` and exits cleanly on
SIGINT/SIGTERM/SIGBREAK).

**Interfaces:** inputs `working-directory` (`.`), `python-version`
(`3.12`) and `publish` (`true`). Output files are per Global Constraints.
The zip root holds `<name>.exe`, `_internal\` and `devstore.json`.
- [ ] Workflow per spec §9.1. It validates `devstore.json`: `name` matches `^[a-z0-9-]+$`, `type` is in {gui, service}, `version` matches `^\d+\.\d+\.\d+$`; otherwise it fails with `::error::`.
- [ ] Commit.

### Task 4: Updater core logic (pure)
**Files:** Create `windows/agent/DevStore.Core.psm1`; test `windows/agent/tests/DevStore.Core.Tests.ps1`.

**Produces:**
- `ConvertFrom-DevStoreTag([string]$Tag) -> [version]|$null` (only `windows-vX.Y.Z`)
- `Select-DevStoreRelease($Releases, [string[]]$Bad) -> release|$null` (skips draft, prerelease, bad and invalid tags; picks the max version)
- `Read-DevStoreJson([string]$Path, $Default) -> object` (missing, empty or corrupt file → `$Default`)
- `Write-DevStoreJson([string]$Path, $Object)` (write to `$Path.tmp`, then move-replace)
- `Get-DevStoreAction($AppState, [string]$Version) -> 'none'|'install'|'update'`
- `Get-DevStorePruneList([string[]]$Versions, [string]$Current, [string]$Previous) -> string[]`
- `Test-DevStoreHash([string]$File, [string]$ShaText) -> bool` (first token of the text, case-insensitive)
- `New-DevStoreWinswXml([string]$Name, [string]$Exe, [string]$LogDir) -> string` (id `devstore-<name>`, `<startmode>Automatic`, `<onfailure action="restart" delay="10 sec"/>`, `<stoptimeout>30 sec`)
- [ ] Write Pester tests: tag parsing (`windows-v1.10.0` > `windows-v1.9.0`; `android-v1.0+3` → null), the Review Focus 1–3 cases, prune keeping current + previous, hash match and mismatch, XML containing `devstore-x`.
- [ ] Run `pwsh -c "Invoke-Pester windows/agent/tests -Output Detailed"` → it fails, then implement → it passes.
- [ ] Commit.

### Task 5: Updater runner
**Files:** Create `windows/agent/DevStore.Agent.psm1`,
`windows/agent/DevStoreUpdater.ps1`; test
`windows/agent/tests/DevStore.Agent.Tests.ps1`.

**Consumes:** Task 4. **Produces:**
- `Get-DevStoreReleases($Repo, $Token)`, `Save-DevStoreAsset($Repo, $AssetId, $Token, $OutFile)`
- `Set-DevStoreJunction($Link, $Target)`, `Test-DevStoreGuiRunning($AppDir) -> bool`
- `Install-DevStoreService`, `Restart-DevStoreServiceSafe($Name) -> bool` (stop with a 30 s timeout, start, wait 30 s, check `Running`)
- `Update-DevStoreApp($Repo, $AppState, $Root, $Token) -> hashtable` (new app state; never throws, and errors go to `lastError`/`status='error'`)
- `Invoke-DevStoreUpdaterRun($Root)` (mutex `Global\DevStoreUpdater`, loads config, state and token, updates every app, writes state with `lastRun`/`lastRunResult`)

Status values written: `ok`, `pending`, `error`, `rolledback`.
- [ ] Pester tests with the side-effect functions mocked: a fresh install of a GUI app → `ok` with a shortcut; a running GUI → `pending`; a service whose health check fails → `rolledback`, the version added to `bad`, the junction back on the previous version; a hash mismatch → `error` with the installed version unchanged; an exception in one app doesn't stop the next.
- [ ] Fail → implement → pass. Commit.

### Task 6: Install and management scripts
**Files:** Create `windows/agent/Install-DevStoreAgent.ps1`,
`Add-DevStoreApp.ps1`, `Remove-DevStoreApp.ps1`, `Start-DevStoreCheck.ps1`,
`Invoke-DevStoreServiceAction.ps1`.
- [ ] Install script: requires admin. It copies `windows/agent/*` to `C:\DevStore\agent\` and asks for the token (DPAPI LocalMachine → `token.dat`). It downloads WinSW v2.12.0 x64 to `tools\winsw.exe`. It sets ACLs per spec §13, registers the task, and adds `qawalah/devstore` to config. It can be re-run safely.
- [ ] `Add`/`Remove` take `-Repo` (validated `^[\w.-]+/[\w.-]+$`); Remove uninstalls the service and shortcut and keeps data. `Start-DevStoreCheck` runs `Start-ScheduledTask 'DevStore Updater'`. The service action script takes `-Name -Action Start|Stop|Restart`.
- [ ] Pester test: the config add/remove helper (`Set-DevStoreConfigApp` in Core) is idempotent. Commit.

### Task 7: DevStore Manager UI
**Files:** Create `windows/manager/{devstore.json,main.py,requirements.txt}`,
`windows/manager/devstore_manager/{__init__.py,model.py,actions.py,ui.py}`,
`windows/manager/tests/{test_model.py,test_actions.py}`,
`.github/workflows/manager-release.yml` (on push to `main` touching
`windows/manager/**`, calls `./.github/workflows/windows-release.yml` with
`working-directory: windows/manager`).

**Produces:** `model.AppRow(repo, name, type, installed, latest, status, last_checked, error)`;
`model.load_json(path, default)`; `model.build_rows(config, state, services) -> list[AppRow]`;
`model.status_text(app_state, service_status) -> str`;
`model.filter_log(lines, name, limit=50)`; `model.footer_text(state) -> str`;
`actions.elevated_args(script, **params) -> str` and
`actions.run_elevated(script, **params)` (ShellExecuteW `runas`, hidden);
`actions.check_now/add_app/remove_app/service_action/launch/open_folder`;
`actions.service_statuses(names) -> dict`.

Status text mapping: `ok` → "Up to date" (services: "Running"/"Stopped"
appended); `pending` → "Update pending (close app)"; `rolledback` → "Failed:
v{bad[-1]} rolled back"; `error` → "Error: {lastError}"; no state →
"Not installed yet".
- [ ] pytest: rows for config apps without state; corrupt state; every status mapping; log filter limit; elevated args quoting a repo; `run_elevated` calling the mocked shell execute with `runas`.
- [ ] Fail → implement → pass (`python -m pytest windows/manager/tests`). Commit.

### Task 8: Docs and handover
**Files:** Create `docs/phone-setup.md`, `docs/windows-setup.md`,
`docs/handover/{README.md,chat-export-prompt.md,onboard-repo.md}`.
- [ ] Content per spec §3.5, §3.6, §10.2 and §13. Commit.

### Task 9: Self-test CI and verification
**Files:** Create `.github/workflows/self-test.yml` (on push and PR): jobs
`pester` (windows-latest, Pester 5.7.1), `manager-tests` (windows-latest,
pytest), `android-build` (calls android-release with `publish: false` on
`samples/hello-android`), `windows-build` (matrix of the 2 samples plus the
manager, `publish: false`).
- [ ] Push; all jobs green on GitHub. Fix until green.
