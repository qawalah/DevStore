# DevStore: install a set of files from a starred repo's release (Design)

Date: 2026-11-19
Status: Draft, waiting for approval. Builds on the starred-app install
described in `docs/windows-setup.md` ("Starred repos") and implemented by
`Update-DevStoreStarredApp` in `windows/agent/DevStore.Agent.psm1`.

## 1. Intent and the why
The user wants DevStore to work out, by itself, **what a third-party release
needs installed** and then **keep it updated**, instead of installing exactly
one file.

The case that triggered this is
[boykopovar/AnyPS5](https://github.com/boykopovar/AnyPS5) v0.1.5, a
command-line converter (`relinker`) for PS5 executables. Per the repo's release
workflow, a release holds (names inferred from `.github/workflows/release.yml`
and `tools/package_release.py` at the default branch; **the release page itself
could not be read, so the fixture in section 7 must be checked against it**):

| File | What it is |
|---|---|
| `relinker-v0.1.5.exe` | the tool (console program) |
| `prx-windows-v0.1.5.zip` | its Windows support libraries (`libs\` folder, DLLs) |
| `prx-windows-unpatched-v0.1.5.zip` | a variant of the libraries |
| `prx-headers-v0.1.5.zip` / `.tar.gz`, `prx-windows-v0.1.5.tar.gz` | headers; same libs as tar.gz |
| `prx-linux-*`, `relinker-v0.1.5` (no extension), `web-v0.1.5.zip` | other systems / browser build |

Today DevStore installs **one** file per release. For this release it would
pick `prx-windows-v0.1.5.zip` (score 10, ties with the unpatched zip, first
wins), find no program to open in it, and fail. It ignores `relinker-v0.1.5.exe`
(no "windows" in the name). The tool only works with the exe **and** the `libs\`
folder side by side, and it is run from a terminal, not opened as a window.

## 2. Goals
- G1. For a starred repo's newest release, DevStore picks the **set** of Windows
  files to install (here: the exe and the libs zip), skipping other systems,
  duplicates/variants, headers, source and installers.
- G2. It installs them together into one folder and keeps them updated on every
  new release, with the same Automatic / Download / Just-tell-me choices.
- G3. It tells a **window app** from a **command-line tool** by reading the
  exe's header, and gives each the right Start-menu shortcut.
- G4. The app's page shows which files were chosen, and a **Choose files...**
  override lets the user correct the choice. The correction is remembered and
  applied to every later release.
- G5. Repos that work today (one `.zip` or one portable `.exe`) behave exactly
  as before.

## 3. Non-goals
- Installers (`setup.exe`, `.msi`): still "Download in browser".
- Archives other than `.zip` (`.7z`, `.tar.gz`) and non-Windows systems.
- Editing `PATH`, or anything needing admin rights.
- Running or testing the installed program (the updater never launches it,
  as today).
- Reading the AnyPS5 repo's contents beyond its release files. Converting games
  is the user's own business with their own files.
- Services: starred apps are never services (unchanged).

## 4. Anti-goals (a failure even if it "works")
- Silently installing a large or wrong set of files. There is a cap (4.3) and
  the page always shows the chosen files.
- Changing what existing single-file starred installs do or where they live.
- Running downloaded code during an update. Checksums are verified exactly as
  today, per file.

## 5. Approaches considered
- **A. Smarter single-file picker.** Small, but cannot install an exe that
  needs its libs folder. Rejected: does not fix the case that started this.
- **B. Pick a set of files automatically, with an override (chosen).** One
  rule set chooses the set, the exe's header says window vs command line, an
  override is stored per repo.
- **C. Hand-written recipe per repo only.** Reliable but DevStore identifies
  nothing by itself. Kept only as the override inside B.

The user chose **B with the override** on 2026-11-19.

## 6. Design

### 6.1 Choosing the set (`DevStore.Core.psm1`, pure, Pester-tested)
New `Select-DevStoreStarredAssets -Assets -Override` returns the ordered list
of assets to install (possibly empty). `Select-DevStoreStarredAsset` (single)
stays for compatibility and returns the first of that list.

1. **Reject** with the existing rules in `Get-DevStoreStarredAssetScore`
   (not `.zip`/`.exe`; Linux/macOS/Android/etc.; ARM; installers; source,
   symbols, debug), plus new rejects: `headers`, `include`, `sdk`, `docs`,
   `web`/`wasm`/`browser`, `checksums`/`sha256`/`sig`.
2. **Group** the rest by a *base name*: lowercase, version removed
   (`v?\d+(\.\d+)+` and the release tag), and the words `windows|win32|win64|win|
   x64|x86_64|amd64|portable|unpatched|patched` removed, extension removed.
   `relinker-v0.1.5.exe` -> `relinker`; `prx-windows-v0.1.5.zip` and
   `prx-windows-unpatched-v0.1.5.zip` -> `prx`.
3. **Within a group choose one file**, by the existing score, minus a penalty
   for variant words (`unpatched`, `legacy`, `lite`, `noavx`, `old`,
   `compat`), then shorter name wins. (So `prx-windows-v0.1.5.zip` beats
   `prx-windows-unpatched-v0.1.5.zip`.) A `.zip` and a `.exe` with the same base
   name are duplicates of one app; the existing score decides, as today.
4. **Every remaining group is installed**, with these limits:
   - A `.zip` with no "windows" in its name is dropped when it is in a group
     alone and no `.exe` group exists (same as today: "could be anything").
   - At most **4** files and **600 MB** total (the summed size of the release
     files as published, i.e. compressed); beyond that DevStore installs
     nothing and says why (the user can then use the override). On a first
     install this is an error; on an update the installed version is kept and
     the same message is shown, as with "no Windows file" today.
5. A single remaining group gives the same result as today (G5).

**Override.** The override is a list of name *patterns*, each a chosen file
name with its **version token** replaced by `*` (`relinker-*.exe`,
`prx-windows-*.zip`), plus optionally the main program's file name. `*` is not
a glob: it stands for one version token only (the same `v?\d+(\.\d+)+` rule as
grouping), so `prx-windows-*.zip` matches `prx-windows-v0.1.6.zip` but **not**
`prx-windows-unpatched-v0.1.6.zip`. When an override exists, steps 1-4 are
skipped: each pattern must match exactly one asset of the release (zero or
more than one is an error, below).
A pattern that matches nothing in a new release is an error shown on the app's
page ("Your chosen file `x-*.zip` is not in v0.1.6"); the installed version is
kept, as with a release without a Windows file today.

### 6.2 Installing and updating (`DevStore.Agent.psm1`)
`Update-DevStoreStarredApp` is changed from "one asset" to "a set":
- Download every chosen asset, verify each one's SHA-256 exactly as now
  (GitHub's digest, else a `<file>.sha256` in the release, else installed as
  downloaded with a log line), unpack `.zip`s into the versioned folder
  (`apps\starred-<owner>--<repo>\versions\<tag>\`) and copy `.exe`s into it.
  `.verified` is written once, after all files are in place.
- A standalone `.exe` whose name is `<stem>-<version>.exe` is saved as
  `<stem>.exe` so the command is the same after every update. Only
  standalone exes are renamed (not exes inside zips), using the same version
  rule as grouping. *(My call; mentioned so it can be checked.)*
- The program is picked with `Select-DevStoreStarredExe` over all exes in the
  folder (or the override's main program). `libs\*.dll` and the like are not
  programs; nothing else changes.
- The zips are unpacked as they are, with no flattening. (AnyPS5's zips hold a
  top-level `libs\` folder per `tools/package_release.py`, so the libraries
  land beside the exe. Hoisting a single wrapper folder would break that.)
- State records `installedFiles` (the chosen file names) next to `installed`.
- **Apps installed before this version (no `installedFiles`) stay in "legacy
  mode":** every update picks exactly one file with the old rule, as today, and
  nothing is reinstalled. They move to the new rules only when the user uses
  **Choose files...** on them. New installs use the new rules.
- **Changing the override applies at once, whatever the update setting**, as
  the user asked for it. It rebuilds the **current** release as a new version
  folder named `<tag>-<4-char hash of the chosen names>` (new installs use this
  name from the start; legacy apps keep the plain tag), switched like an
  update, with the old set as "previous". If the app is running it waits for
  the app to close ("pending"), as updates do.
- **Automatic install of repos you star from now on** installs only when the
  chosen set is a single file, as today. A set of several files needs a click
  on **Install**. *(My call: keeps "silent" installs to what they always were.)*
- The override is read from `config.json` by the updater and passed to
  `Update-DevStoreStarredApp` as a new `-Override` parameter.
- Update modes (auto / download / notify), waiting for a running app to close,
  keeping current + previous folder, rollbacks of status and the log lines are
  unchanged.
- Updates keep going through the existing hourly starred check.

### 6.3 Window app or command-line tool
New `Get-DevStorePeSubsystem -Path` reads the exe's PE header
(`e_lfanew` -> optional header `Subsystem`: 2 = window, 3 = console; anything
else or an unreadable file = window, today's behaviour).
- The type comes from the **main program only** (the one exe `exe` and the
  shortcut point at). An app has one main program, even if the set holds
  several exes.
- **Window** -> unchanged (`type = 'gui'`, Start-menu shortcut to the exe).
- **Console** -> `type = 'cli'`. The Start-menu shortcut is named
  `<Name> (command line)` and opens PowerShell (`-NoExit`) in the app's
  `current` folder with that folder at the front of `PATH` for that window
  only, so `relinker --windows in.elf app.exe` just works. Nothing on the PC's
  `PATH` is changed.
- The updater never starts either kind. "Waiting for the app to close" keeps
  using the running-process check, which sees `relinker.exe` mid-run.

### 6.4 Window (`windows/manager`)
- The release entry (`ConvertTo-DevStoreStarredEntry`) keeps
  `latest.windows` (now the first chosen file, for compatibility) and adds
  `latest.windowsFiles` (all chosen files, name + size) and
  `latest.windowsOverride` (true when the user's choice is used).
- **App page, before install** (`Install on this PC`): "DevStore will install:
  `relinker-v0.1.5.exe`, `prx-windows-v0.1.5.zip`" and a **Choose files...**
  link. It is also reachable after install.
- **Choose files...** lists every file of the newest release with checkboxes
  (current choice ticked), a **Main program** dropdown limited to chosen
  `.exe` files when there are several, **Use these files** and **Back to
  automatic**. It sends a new `set-files` request (`repo`, `patterns`,
  `main`, or `clear: true`) through the existing requests folder; the updater
  validates it (`ConvertFrom-DevStoreRequest`) and stores it in `config.json`
  under a top-level `starredFiles` map keyed by repo (`patterns`, `main`), not
  on the app's entry. That way an override can be set before the app is
  installed, without creating a half-installed app.
- The Installed page and app page show "Command-line tool" for `cli` apps,
  with **Open terminal** in place of **Open** (it runs the same shortcut).
- `docs/windows-setup.md` ("Starred repos") is updated to describe the set,
  the command-line shortcut and Choose files.

### 6.5 Versions
- `windows/agent/VERSION`: 2.8.0 -> 2.9.0 (installed updaters only update to a
  higher version).
- `windows/manager/devstore.json` version bumped (the Manager release carries
  the agent scripts).

## 7. Testing
Pester (agent) and pytest (manager), as the repo does today:
- **Set selection** with fixtures: AnyPS5 v0.1.5 (the names in section 1:
  expect `relinker-v0.1.5.exe` + `prx-windows-v0.1.5.zip`); a repo with only
  `tool-win64.zip`; one with `tool-win64.zip` + `tool-win64-portable.exe`
  (one app, not two); one with only an installer; many variants (cap and
  size limit); the existing tests for single files stay green unchanged.
- **Override**: pattern matching across a version bump, a pattern that matches
  nothing, a `set-files` request with bad input rejected.
- **PE subsystem**: tiny synthetic headers for window, console, truncated and
  non-PE files.
- **Install flow**: update logic with mocked download (several files, one bad
  checksum fails the whole release and keeps the old one, `installedFiles`
  change reinstalls the same tag, update modes unchanged).
- **Manager**: `set-files` request written correctly, API method, entry fields.
- **The fixture is not verified against the real release page** (not
  reachable from the build environment). The first time DevStore runs against
  AnyPS5 for real, compare the asset list and fix the fixture if it differs.

## 8. Left to the builder
- Exact regexes for base-name grouping and the variant word list (start from
  section 6.1, extend by test).
- The shortcut's exact PowerShell command line and how to quote paths with
  spaces.
- Layout and wording of the Choose files screen, following `docs/design/` and
  `docs/lessons/LESSONS.md` (read both before touching the window).
- How `cli` apps appear where `gui` is assumed in the window and updater
  (grep for `'gui'` / `type`).
