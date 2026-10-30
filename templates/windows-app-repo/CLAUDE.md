# DevStore app repo rules (Windows: Python, Go or C#/.NET)

This app is released through DevStore. Pushing to `main` builds it on GitHub:
Python with PyInstaller, Go with `go build`, C# with `dotnet publish`. A new
`version` in `devstore.json` publishes a GitHub Release, which the DevStore
Updater on the user's Windows PC installs within about 10 minutes.

## devstore.json
- `name`: lowercase letters, digits and dashes. **Never change it.** It's the
  app's identity on the PC (install folder, service name, data folder). The
  build always produces `<name>.exe`.
- `language`: `python` (default), `go` or `dotnet`. Don't change it after the
  first release.
- `type`: `gui` (window/tray app) or `service` (always-on background
  process). Don't change it after the first release.
- `entry`:
  - Python: the file to run.
  - Go: the package to build, such as `.` or `./cmd/server` (needs `go.mod`
    next to `devstore.json`).
  - .NET: the app's `.csproj`. It's published as a self-contained single
    file for win-x64, and the exe is renamed to `<name>.exe`.
- `version`: `MAJOR.MINOR.PATCH`. **Bump it for every change the user should
  receive.** No bump means no release (the build still runs as a check).
- Store listing (shown in the DevStore window), all optional:
  - `displayName`: the app's name, for example `"SimDeck Companion"`.
  - `description`: one or two plain sentences about what the app does.
  - `icon`: a square PNG in the repo (256×256 is ideal), for example
    `"store/icon.png"`.
  - `screenshots`: up to 6 PNGs, for example `["store/1.png", "store/2.png"]`.
- Optional:
  - `data` (Python only): folders the app reads at runtime, bundled at the
    same path, for example `["web"]`.
  - `include`: a list of files or folders, relative to `devstore.json`,
    shipped next to the exe.
  - `prepare`: a `.ps1` script run after the build. It can put extra parts
    (for example a downloaded engine) into the folder in `$env:DEVSTORE_OUT`.
  - `updateWhileRunning`: `true` for tray apps that keep running. The update
    is installed while the app runs, and the new version starts the next time
    it's opened. Without it, updates wait until the app is closed.

## Rules for the code
- **Store data, settings and logs outside the install folder**: in
  `%ProgramData%\<name>\`, or in the user's profile for per-user settings.
  Never write next to the exe: the install folder is replaced on every update.
- **Python:** list every third-party dependency in `requirements.txt`. The app
  must run as a frozen PyInstaller onedir build. Locate bundled files with
  `sys._MEIPASS` when `getattr(sys, "frozen", False)`.
- **Go:** keep `go.mod` and `go.sum` committed. The build is a single static
  exe (`CGO_ENABLED=0`). `var version = "dev"` in package `main` is set to the
  version at build time. Embed web assets with `go:embed`, or ship them with
  `include`.
- **.NET:** the version is passed as `-p:Version`. Read it from the assembly
  version.
- **Services only:**
  - Run in the foreground, with no daemonizing or self-detaching.
  - Exit cleanly within 20 seconds on Ctrl+C / SIGTERM (Python: also
    SIGBREAK; Go: `signal.Notify` for `os.Interrupt` and `syscall.SIGTERM`).
  - Crashes are restarted automatically, but a version that won't stay up
    for 30 seconds is rolled back and marked bad.
  - Services run as SYSTEM: don't rely on the user's profile, mapped drives
    or desktop.
  - DevStore installs the service itself (as `devstore-<name>`). If the app
    has its own "install as a service" command, don't use it on a
    DevStore-managed PC, or there'll be two copies.
- **GUI apps:** unless `updateWhileRunning` is set, an update waits until the
  app is closed, so don't leave hidden processes running after the window
  closes.

## Releasing
When a change is done: bump `version`, commit, push to `main`. That push *is*
the release. If the Release workflow fails, read its log in the Actions tab
and fix it. `HANDOVER.md` (if present) holds history from the original
Claude chat.
