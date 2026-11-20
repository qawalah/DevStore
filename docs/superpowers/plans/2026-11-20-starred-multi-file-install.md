# Starred multi-file install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DevStore picks the set of Windows files a starred repo's release needs (for AnyPS5 v0.1.5: `relinker-v0.1.5.exe` + `prx-windows-v0.1.5.zip`), installs them together, tells a window app from a command-line tool, keeps them updated, and lets the user override the choice.

**Architecture:** Pure selection/parsing logic goes in `windows/agent/DevStore.Core.psm1` (Pester-tested). `Update-DevStoreStarredApp` in `DevStore.Agent.psm1` is changed from one asset to a set, with a "legacy" path that keeps today's behaviour for apps installed before this change. The Manager (Python + web UI) shows the chosen files and sends a new `set-files` request through the existing requests folder.

**Tech Stack:** PowerShell 5.1-compatible modules + Pester 5.7.1; Python 3 + pytest; plain JS/HTML/CSS web UI in `windows/manager/devstore_manager/web/`.

**Spec:** `docs/superpowers/specs/2026-11-19-starred-multi-file-install-design.md` (read it first; section numbers below refer to it).

## Global Constraints
- Agent `windows/agent/VERSION` goes `2.8.0` -> `2.9.0`; `windows/manager/devstore.json` `version` goes `2.8.0` -> `2.9.0`.
- At most **4** files and **600 MB** (600 * 1024 * 1024 bytes of published asset sizes) per set; over either: install nothing, show the message, keep the installed version on updates.
- Only `.zip` and `.exe` assets; installers, other systems, ARM, source, symbols, debug, headers, sdk, docs, web/wasm/browser, checksums/signatures are never installed.
- Override patterns replace only the **version token** with `*` (not a glob). Zero or more than one match is an error.
- Version folder for non-legacy installs: `<tag>-<4 hex chars of SHA-256 of the sorted, lower-cased chosen names joined by "|">`; legacy installs keep the plain tag folder.
- Legacy mode = installed app whose state has no `installedFiles` and no override: exactly one file per update by the old `Select-DevStoreStarredAsset`, old folder name, always `type = 'gui'`.
- Command-line tools get the Start-menu shortcut `<Name> (command line)` opening `powershell.exe -NoExit` in the app's `current` folder with that folder prepended to `PATH` for that window only. No change to the machine `PATH`; no admin.
- Override storage: top-level `starredFiles` map in `config.json`, keyed by repo (`patterns`, `main`). Request name: `set-files`.
- Automatic install of newly starred repos only when the chosen set is a single file.
- A standalone exe named `<stem>-<version>.exe` is saved as `<stem>.exe`; exes inside zips keep their names; zips are unpacked as they are (no flattening).
- Before touching the window, read `docs/design/DESIGN.md` and `docs/lessons/LESSONS.md`.
- Commits end with the two attribution lines from the session's system reminder.
- **Testing environment:** Python tests run locally (`cd windows/manager && python3 -m pytest`). `pwsh` is not installed in this container; try `apt-get install -y powershell` or the PowerShell GitHub release once, and if that fails run Pester through CI (`self-test.yml` job `pester` on `windows-latest`): push the branch and check the run with `mcp__github__actions_list`. The Agent module uses Windows-only calls, so CI is the authority.

## Review Focus
- A release with only installers / other-OS files: nothing installed, a plain message, no crash (Task 1).
- Asset names in odd case or with spaces (`AnyPS5-Win64.ZIP`, `Tool Windows.zip`): matched case-insensitively (Task 1, 2).
- A set where one download fails or its hash is wrong halfway: old version and shortcuts untouched (Task 4).
- Two exes in the set (tool plus a helper such as `crashpad_handler.exe`): the main program is the right one; an override `main` wins (Task 4).
- A `set-files` request with path characters, wildcards beyond `*`, or too many patterns: ignored as invalid (Task 2).
- A truncated or non-PE exe: treated as a window app, never an error (Task 3).

---

### Task 1: Choose the set of files (automatic)

**Files:**
- Modify: `windows/agent/DevStore.Core.psm1` (new functions next to `Select-DevStoreStarredAsset`, ~line 477; add to `Export-ModuleMember` list near line 714-723)
- Test: `windows/agent/tests/DevStore.Core.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-DevStoreAssetBaseName -Name <string> -Tag <string> -> [string]`: lower-case, extension removed, the tag and any `v?\d+(\.\d+)+` removed, then the words `windows|win32|win64|win|x64|x86_64|x86-64|amd64|portable|unpatched|patched` removed (as whole tokens), separators collapsed and trimmed. `relinker-v0.1.5.exe` -> `relinker`; `prx-windows-unpatched-v0.1.5.zip` -> `prx`.
  - `ConvertTo-DevStoreStandaloneExeName -Name <string> -Tag <string> -> [string]`: `relinker-v0.1.5.exe` -> `relinker.exe`; a name without a version token is returned unchanged.
  - `Select-DevStoreStarredAssets -Assets <object[]> -Tag <string> -Override <hashtable|$null> = $null -> @{ assets = @(<asset objects>); error = <string|$null> }` (override handling is added in Task 2; here `-Override` is accepted and ignored).
- Consumes: existing `Get-DevStoreStarredAssetScore` (returns `$null` for rejected names), `Select-DevStoreStarredAsset` (unchanged, still the legacy single pick).

- [ ] **Step 1: Write the failing tests** in a new `Describe 'Select-DevStoreStarredAssets'` block. Assets are `[pscustomobject]@{ name = ...; size = ...; id = ... }`. Tests:
  - `picks the exe and the libs zip for AnyPS5 v0.1.5`: assets = the full list in spec section 1 (`relinker-v0.1.5.exe`, `relinker-v0.1.5`, `prx-windows-v0.1.5.zip`, `prx-windows-v0.1.5.tar.gz`, `prx-windows-unpatched-v0.1.5.zip`, `prx-linux-v0.1.5.zip`, `prx-headers-v0.1.5.zip`, `prx-headers-v0.1.5.tar.gz`, `web-v0.1.5.zip`); expect `(... ).assets.name | Sort-Object` to equal `@('prx-windows-v0.1.5.zip','relinker-v0.1.5.exe')` and `.error` null.
  - `a zip and a portable exe of the same app are one app`: `tool-win64.zip` + `tool-win64-portable.exe` -> exactly one asset, the same one `Select-DevStoreStarredAsset` returns.
  - `a single windows zip behaves as before`: `tool-1.2-windows-x64.zip` + `tool-1.2-linux.tar.gz` -> that zip only.
  - `only installers or other systems gives no files and no error`: `setup.exe`, `tool.msi`, `tool-linux.zip` -> `assets` empty, `error` null.
  - `case does not matter`: `AnyPS5-Win64.ZIP` is chosen.
  - `more than 4 files is refused with a message`: 5 distinct-base windows zips -> `assets` empty, `error` matches `more Windows files`.
  - `more than 600 MB is refused`: two windows zips of 400 MB each -> `assets` empty, `error` matches `MB`.
  - `ConvertTo-DevStoreStandaloneExeName` cases above, plus `tool.exe` unchanged.

- [ ] **Step 2: Run to verify they fail.** Run: `Invoke-Pester -Path windows/agent/tests/DevStore.Core.Tests.ps1 -FullNameFilter '*Select-DevStoreStarredAssets*'` (or via CI). Expected: FAIL, functions not found.

- [ ] **Step 3: Implement** the three functions and export them. Approach: reject = existing score `$null` or a whole-token match of `headers|include|sdk|docs|web|wasm|browser|checksums|sha256|sig` (extend with a small helper, do not change `Get-DevStoreStarredAssetScore`, which the legacy path relies on); group by `Get-DevStoreAssetBaseName`; per group take highest `score - 20 * (count of variant words unpatched|legacy|lite|noavx|old|compat)`, ties by shorter name, then input order; return groups ordered by base name; apply the 4-file / 600 MB limits with the messages "This release has more Windows files than DevStore installs by itself (N files, X MB). Use Choose files… to pick what you need."

- [ ] **Step 4: Run to verify they pass**, same command. Expected: PASS, and the existing `Select-DevStoreStarredAsset` tests still pass.

- [ ] **Step 5: Commit** `Choose a set of Windows files from a starred release`.

### Task 2: Overrides: patterns, config storage and the `set-files` request

**Files:**
- Modify: `windows/agent/DevStore.Core.psm1` (`Select-DevStoreStarredAssets`, `ConvertFrom-DevStoreRequest` ~line 238, new config helpers near `Set-DevStoreConfigApp` ~line 212, exports)
- Test: `windows/agent/tests/DevStore.Core.Tests.ps1`

**Interfaces:**
- Produces:
  - `ConvertTo-DevStoreAssetPattern -Name <string> -Tag <string> -> [string]` (`relinker-v0.1.5.exe` -> `relinker-*.exe`; no version token -> the name unchanged).
  - `Test-DevStoreAssetPattern -Pattern <string> -Name <string> -> [bool]`: case-insensitive, whole name; `*` stands for exactly one `v?\d+(\.\d+)+` token and nothing else.
  - `Set-DevStoreStarredFiles -Config <hashtable> -Repo <string> -Patterns <string[]> -Main <string> = '' -Clear <bool> = $false -> hashtable` (case-insensitive repo key; `-Clear` removes the entry).
  - `Get-DevStoreStarredFiles -Config <hashtable> -Repo <string> -> $null | @{ patterns = @(...); main = <string> }`.
  - `Select-DevStoreStarredAssets` with a non-null `-Override` returns one asset per pattern, or `error` = `Your chosen file <pattern> is not in <tag>.` (zero matches) / `Your chosen file <pattern> matches more than one file in <tag>.`
  - Request `@{ action='set-files'; repo; mode=$null; patterns=<string[]>; main=<string>; clear=<bool> }`.
- Consumes: Task 1 functions.

- [ ] **Step 1: Write the failing tests**:
  - `prx-windows-*.zip` matches `prx-windows-v0.1.6.zip` and does **not** match `prx-windows-unpatched-v0.1.6.zip`; matching is case-insensitive.
  - pattern round trip: `ConvertTo-DevStoreAssetPattern 'relinker-v0.1.5.exe' 'v0.1.5'` is `relinker-*.exe`.
  - override survives a version bump: assets for v0.1.6 with patterns `relinker-*.exe`, `prx-windows-*.zip` give the v0.1.6 files.
  - override with a pattern that matches nothing -> `assets` empty and the exact "is not in" message; two matches -> the "more than one" message.
  - `Set-DevStoreStarredFiles` stores and `Get-DevStoreStarredFiles` reads regardless of repo case; `-Clear` removes it; other keys untouched.
  - `ConvertFrom-DevStoreRequest`: valid `set-files` accepted (`patterns`, `main`); `clear = $true` with no patterns accepted; rejected (`$null`): empty patterns without clear, more than 4 patterns, a pattern containing `/`, `\`, `..`, a space-only name or `;`, a pattern not ending `.zip`/`.exe`, `main` not ending `.exe`, invalid repo.

- [ ] **Step 2: Run to verify they fail** (`-FullNameFilter '*override*','*set-files*'` or CI). Expected: FAIL.

- [ ] **Step 3: Implement** the functions above. Pattern/`main` validation regex: `^[A-Za-z0-9._+*-]{1,120}\.(zip|exe)$` for patterns, `^[A-Za-z0-9._+-]{1,120}\.exe$` for `main`.

- [ ] **Step 4: Run to verify they pass.** Expected: PASS, all existing request tests unchanged.

- [ ] **Step 5: Commit** `Add set-files overrides for starred installs`.

### Task 3: Window app or command-line tool

**Files:**
- Modify: `windows/agent/DevStore.Core.psm1` (new functions, exports); `windows/agent/DevStore.Agent.psm1` (`New-DevStoreShortcut` ~line 197, `Remove-DevStoreAppCore` ~line 738)
- Test: `windows/agent/tests/DevStore.Core.Tests.ps1`, `windows/agent/tests/DevStore.Agent.Tests.ps1`

**Interfaces:**
- Produces:
  - `Get-DevStorePeSubsystem -Bytes <byte[]> -> 'gui' | 'cli'`: read `e_lfanew` at offset 0x3C, check `PE\0\0`, optional header `Subsystem` word at (PE offset + 24 + 68): `3` -> `'cli'`; everything else, including truncated or non-PE input -> `'gui'`.
  - `Get-DevStorePeSubsystemOfFile -Path <string> -> 'gui' | 'cli'` (reads the first 4096 bytes; unreadable -> `'gui'`).
  - `Get-DevStoreCliShortcutArguments -Dir <string> -> [string]`: the argument string for `powershell.exe`: `-NoExit -NoProfile -ExecutionPolicy Bypass -Command "$env:Path = '<dir>;' + $env:Path; Set-Location -LiteralPath '<dir>'"`, with single quotes in `<dir>` doubled.
  - `New-DevStoreShortcut -DisplayName <string> -Target <string> [-Arguments <string>] [-WorkingDirectory <string>]` (new optional parameters; default behaviour unchanged).
  - `Remove-DevStoreAppCore` also calls `Remove-DevStoreShortcut -DisplayName "<displayName> (command line)"`.

- [ ] **Step 1: Write the failing tests**: build byte arrays in the test (DOS header with `MZ`, `e_lfanew = 0x80`, `PE\0\0` at 0x80, subsystem word at 0x80+24+68): subsystem 2 -> `gui`, 3 -> `cli`; empty array, 10 bytes, `MZ` with `e_lfanew` beyond the buffer, and a text file -> `gui`. `Get-DevStoreCliShortcutArguments -Dir "C:\DevStore\apps\o's tool\current"` contains the doubled quote and `-NoExit`. Agent test: `Remove-DevStoreAppCore` (existing test style, shortcut mocked) removes both shortcut names.

- [ ] **Step 2: Run to verify they fail.** Expected: FAIL.

- [ ] **Step 3: Implement** as specified; `New-DevStoreShortcut` sets `$lnk.Arguments` and `$lnk.WorkingDirectory` only when given.

- [ ] **Step 4: Run to verify they pass.** Expected: PASS.

- [ ] **Step 5: Commit** `Tell window apps from command-line tools`.

### Task 4: Install and update a set (Agent)

**Files:**
- Modify: `windows/agent/DevStore.Agent.psm1` (`Update-DevStoreStarredApp` ~lines 504-683; extract `Save-DevStoreVerifiedAsset`; new `Get-DevStoreStarredFolderName` goes in Core)
- Modify: `windows/agent/DevStore.Core.psm1` (`Get-DevStoreStarredFolderName`, exports)
- Test: `windows/agent/tests/DevStore.Agent.Tests.ps1` (new `Describe 'Update-DevStoreStarredApp: sets'`, copying the mock setup at lines 38-57 of that file)

**Interfaces:**
- Produces:
  - `Get-DevStoreStarredFolderName -Tag <string> -Names <string[]> -> [string]` (spec section 6.2 format).
  - `Save-DevStoreVerifiedAsset -Repo <string> -Release <object> -Asset <object> -Token <string> -Root <string> -OutFile <string>`: downloads with `Save-DevStoreAsset`, checks the SHA-256 (GitHub digest, else `<name>.sha256` release file, else log "no published checksum"), deletes the file and throws on mismatch (the existing message).
  - `Update-DevStoreStarredApp ... [-Override <hashtable>] = $null`: same parameters and never-throws contract as today. State gains `installedFiles` (string[] of chosen names) and `type` becomes `'cli'` or `'gui'` from the main program (`Get-DevStorePeSubsystemOfFile`); legacy installs keep `'gui'`.
- Consumes: Tasks 1-3 (`Select-DevStoreStarredAssets`, `ConvertTo-DevStoreStandaloneExeName`, `Get-DevStorePeSubsystemOfFile`, `Get-DevStoreCliShortcutArguments`, `New-DevStoreShortcut -Arguments`).

- [ ] **Step 1: Write the failing tests** (mock `Save-DevStoreAsset` to write small files; for zips create a real zip with `Compress-Archive` containing `libs\a.dll`; mock `Get-DevStorePeSubsystemOfFile` for `cli`):
  - first install of the AnyPS5 v0.1.5 list: both files land in `versions\<folder>\`, exe saved as `relinker.exe`, `libs\a.dll` beside it, `installedFiles` = the two names, `type = 'cli'`, `New-DevStoreShortcut` called once with `DisplayName` `AnyPS5 (command line)` and `-Arguments` set; folder name equals `Get-DevStoreStarredFolderName`.
  - a window app set keeps `type = 'gui'` and the plain shortcut `DisplayName 'tool'`.
  - update v0.1.5 -> v0.1.6 re-selects by name (`relinker-v0.1.6.exe`, `prx-windows-v0.1.6.zip`) and switches `current`; `previous` = v0.1.5.
  - one asset's hash mismatches: result `status = 'error'`, `installed` still v0.1.5, `New-DevStoreShortcut` not called, `Set-DevStoreJunction` not called.
  - set over the cap on an update: `status = 'error'`, message from Task 1, installed version kept; on a first install: `status = 'error'`.
  - legacy: state with `installed = 'v1'`, no `installedFiles`, release v2 with exe + zip assets -> exactly one file installed (the old pick), plain tag folder, `type = 'gui'`, no `installedFiles` written.
  - override opt-in: same legacy state plus `-Override @{patterns=...}` -> uses the new rules, `installedFiles` written.
  - same tag, changed override with `-Apply`: new folder (different hash suffix), `previous` = the old folder's tag, old set kept as previous; with the app running (`Test-DevStoreGuiRunning` true) -> `status = 'pending'`.
  - same tag, same files, no override change -> `status = 'ok'`, no download (`Save-DevStoreAsset` not called).
  - two exes in the set (`tool.exe`, `crashpad_handler.exe`): the main program is `tool.exe`; override `main = 'crashpad_handler.exe'` wins.

- [ ] **Step 2: Run to verify they fail** (CI or local pwsh). Expected: FAIL.

- [ ] **Step 3: Implement.** Keep the existing flow and messages (modes `auto`/`download`/`notify`, `pending`, previous-folder pruning, `.verified` written last). Decide `legacy = $s['installed'] -and -not $s.ContainsKey('installedFiles') -and -not $Override`. Non-legacy: `Select-DevStoreStarredAssets -Assets $release.assets -Tag $tag -Override $Override`; an empty set or an `error` takes the existing "no Windows download" branch with the selector's message when there is one. `action = 'none'` only when `installed -eq $tag` and (legacy or the sorted lower-cased `installedFiles` equal the chosen names). Main program: `Select-DevStoreStarredExe`, or the override's `main` matched by leaf name case-insensitively (error if absent). Switching shortcuts: when the type changes, remove the other shortcut name.

- [ ] **Step 4: Run to verify they pass.** Expected: PASS, existing `Update-DevStoreStarredApp` tests unchanged and green.

- [ ] **Step 5: Commit** `Install starred releases as a set of files`.

### Task 5: Release entry and automatic install

**Files:**
- Modify: `windows/agent/DevStore.Core.psm1` (`ConvertTo-DevStoreStarredEntry` ~line 406, `Get-DevStoreStarredAutoInstall` ~line 549)
- Test: `windows/agent/tests/DevStore.Core.Tests.ps1`

**Interfaces:**
- Produces: `ConvertTo-DevStoreStarredEntry -Repo -Releases [-Override <hashtable>]` where `latest` gains `windowsFiles` (array of `@{ name; size }`), `windowsOverride` (`$true` when an override produced the set), `windowsError` (string or `$null`); `latest.windows` stays the first file (or `$null` when the set is empty or errored). `Get-DevStoreStarredAutoInstall` installs only repos whose `latest.windowsFiles` has exactly 1 entry (when the key is absent, falls back to `latest.windows` as today).
- Consumes: Tasks 1-2.

- [ ] **Step 1: Write the failing tests**: AnyPS5 list -> `windowsFiles.Count -eq 2`, `windows.name -eq 'prx-windows-v0.1.5.zip'` or the first by base order (assert the count and names set, not the order), `windowsOverride` false; with `-Override` patterns -> `windowsOverride` true and the matching files; over-cap list -> `windowsError` set, `windows` null; existing entry tests unchanged. Auto-install: a repo with 2 files is skipped, a repo with 1 file installed, existing hashtable-only tests (`windows` without `windowsFiles`) still pass.

- [ ] **Step 2: Run to verify they fail.** Expected: FAIL.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify they pass.** Expected: PASS.

- [ ] **Step 5: Commit** `Show the chosen file set in starred entries; auto-install single files only`.

### Task 6: Wire the updater

**Files:**
- Modify: `windows/agent/DevStore.Agent.psm1` (`Update-DevStoreStarred` ~line 702: add `[hashtable]$Config = @{}` and pass `-Override (Get-DevStoreStarredFiles ...)` to `ConvertTo-DevStoreStarredEntry`; `Invoke-DevStoreRequests` ~line 837; the main loop ~lines 1225-1266; the module's export list at ~line 1331)
- Modify: `windows/agent/VERSION` -> `2.9.0`
- Test: `windows/agent/tests/DevStore.Agent.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-DevStoreRequests` handles `set-files`: stores (or clears) the override with `Set-DevStoreStarredFiles`, adds the repo to the apply list (like `set-channel`) and logs `now using your chosen files` / `back to automatic files`. The main loop passes `-Override (Get-DevStoreStarredFiles -Config $config -Repo $repo)` to `Update-DevStoreStarredApp`, and `-Config $config` to `Update-DevStoreStarred`.
- Consumes: Tasks 2, 4, 5.

- [ ] **Step 1: Write the failing tests** next to the existing `set-channel` request test (~line 537 of the Agent tests): a `set-files` request file results in `config.starredFiles['someone/tool'].patterns` set and `apply` containing the repo; `clear` removes it; an invalid request is logged as ignored. A main-loop-level test is not needed; assert `Update-DevStoreStarredApp` receives the override with a `Mock ... -ParameterFilter` in the existing loop test style if one exists, else skip.

- [ ] **Step 2: Run to verify they fail.** Expected: FAIL.

- [ ] **Step 3: Implement**, then bump `VERSION` to `2.9.0`.

- [ ] **Step 4: Run the whole Pester suite** (CI `pester` job, or locally `Invoke-Pester windows/agent/tests`). Expected: all green.

- [ ] **Step 5: Commit** `Wire starred file overrides into the updater; bump updater to 2.9.0`.

### Task 7: Manager back end (Python)

**Files:**
- Modify: `windows/manager/devstore_manager/actions.py` (new `set_starred_files` next to `install_starred` ~line 138; `cli_shortcut_path`), `windows/manager/devstore_manager/api.py` (`set_starred_files`, `open_app` ~line 193), `windows/manager/devstore_manager/starred.py` (`build` ~line 19), `windows/manager/devstore_manager/store.py` (type label ~line 231)
- Test: `windows/manager/tests/test_actions.py`, `test_starred.py`, `test_store.py`

**Interfaces:**
- Produces:
  - `actions.set_starred_files(repo: str, patterns: list[str], main: str = "", clear: bool = False) -> None`: validates with the same regexes as Task 2 (raise `ValueError` with a plain message), writes request `{"action": "set-files", "repo", "patterns", "main", "clear"}` via `_write_request`, then `start_updater()`.
  - `Api.set_starred_files(self, repo, patterns, main="", clear=False) -> dict` (via `_result`, message "Using your chosen files. This takes under a minute." / "Choosing files automatically again.").
  - `starred.build` items gain `files` (list of `{name, size}` from `latest.windowsFiles`, `[]` when absent), `override` (bool from `latest.windowsOverride`), `filesError` (str or None); `installable` = `bool(files)` when `windowsFiles` is present, else today's rule.
  - `store.py`: `type_label` for `cli` is `"Command-line tool"`.
  - `Api.open_app`: for an app whose state `type` is `cli`, open `actions.cli_shortcut_path(displayName)` (`%ProgramData%\Microsoft\Windows\Start Menu\Programs\DevStore\<displayName> (command line).lnk`) with `launch`, instead of the exe.

- [ ] **Step 1: Write the failing tests**: `set_starred_files` writes the expected JSON request (use the existing request-folder fixture/monkeypatch style in `test_actions.py`) and rejects `"a/b.zip"`, `"x;y.exe"`, an empty list without `clear`, 5 patterns; `starred.build` carries `files`/`override`/`filesError` and `installable` for the AnyPS5 two-file entry and for an old-style entry with only `windows`; `store` gives the `cli` label; `cli_shortcut_path("AnyPS5")` ends with `AnyPS5 (command line).lnk`.

- [ ] **Step 2: Run to verify they fail.** Run: `cd windows/manager && python3 -m pytest tests -k "files or cli or starred" -v`. Expected: FAIL.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run to verify they pass.** Run: `cd windows/manager && python3 -m pytest`. Expected: all pass.

- [ ] **Step 5: Commit** `Manager: set-files request, file set in starred items, command-line apps`.

### Task 8: Manager window: show files and Choose files...

**Files:**
- Modify: `windows/manager/devstore_manager/web/app.js` (`starInstallHtml` ~line 363, the app page action labels, a new `renderChooseFiles` route), `web/app.css`, `web/index.html` only if a new container is needed
- No unit tests exist for the JS; verify with a browser run (Step 3).

**Interfaces:**
- Consumes: Task 7 API: item fields `files`, `override`, `filesError`, `api().set_starred_files(repo, patterns, main, clear)`, and the existing `api().get_starred()`.
- Produces: UI behaviour from spec 6.4:
  - Before install: "DevStore will install: `<name>` (size), `<name>` (size)" for the set, a **Choose files…** link, `filesError` text when set; the single-file text stays as is when the set has one file and no override.
  - **Choose files…** screen: every asset of the newest release (`latest.assets`) with checkboxes (the current set ticked), a **Main program** dropdown only when more than one chosen file is an `.exe`, **Use these files** (patterns from names by replacing the release's version token with `*`, same rule as `ConvertTo-DevStoreAssetPattern`; at most 4 ticked) and **Back to automatic** (shown when `override`). Also reachable from the installed app's page.
  - `cli` apps: "Command-line tool" label; the **Open** button reads **Open terminal**.

- [ ] **Step 1: Read** `docs/design/DESIGN.md`, `docs/lessons/LESSONS.md` and the existing `starInstallHtml`/`modeSelect` code, and reuse their components and wording style (plain words, no jargon).

- [ ] **Step 2: Implement** the UI changes above.

- [ ] **Step 3: Verify in a browser.** Serve `windows/manager/devstore_manager/web/` and open it with Playwright (preinstalled Chromium) with a stub `window.pywebview.api` returning an AnyPS5-like starred item; take a screenshot (`deviceScaleFactor: 1`) of the repo page and the Choose files screen and check: both files listed, ticks match, **Use these files** calls `set_starred_files` with `["relinker-*.exe","prx-windows-*.zip"]`, no console errors. Expected: matches the description above.

- [ ] **Step 4: Commit** `Manager window: show the chosen files and Choose files…`.

### Task 9: Docs, Manager version, final check

**Files:**
- Modify: `docs/windows-setup.md` ("Starred repos" section), `windows/manager/devstore.json` (`version` -> `2.9.0`), `README.md` only if it describes the starred rule (one-line)

- [ ] **Step 1: Update `docs/windows-setup.md`**: replace "What DevStore can install" with the set rules (exe + libs zip, variants skipped), add "Command-line tools" (the `(command line)` shortcut, nothing added to PATH), "Choose files…" and the legacy note (apps installed earlier keep one file until you choose files).

- [ ] **Step 2: Bump** `windows/manager/devstore.json` to `2.9.0`; confirm `windows/agent/VERSION` is `2.9.0`.

- [ ] **Step 3: Run everything.** `cd windows/manager && python3 -m pytest` (expected: all pass); push the branch and check the `self-test` run's `pester` and Manager jobs are green via `mcp__github__actions_list` / `actions_get` (expected: success).

- [ ] **Step 4: Commit and push** `Document starred file sets; release 2.9.0` to `claude/vibrant-gauss-uavbf5`. Do not open a pull request unless asked.
