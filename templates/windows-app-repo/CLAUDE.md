# DevStore app repo rules (Windows, Python)

This app is released through DevStore. Pushing to `main` builds it on GitHub
with PyInstaller. A new `version` in `devstore.json` publishes a GitHub
Release, which the DevStore Updater on the user's Windows PC installs within
about 10 minutes.

## devstore.json
- `name`: lowercase letters, digits and dashes. **Never change it.** It's the
  app's identity on the PC (install folder, service name, data folder).
- `type`: `gui` (window/tray app) or `service` (always-on background
  process). Don't change it after the first release.
- `entry`: the Python file to run.
- `version`: `MAJOR.MINOR.PATCH`. **Bump it for every change the user should
  receive.** No bump means no release (the build still runs as a check).

## Rules for the code
- **Store data, settings and logs in `%ProgramData%\<name>\`**, using
  `os.environ["ProgramData"]`. Never write next to the exe: the install
  folder is replaced on every update.
- List every third-party dependency in `requirements.txt`.
- The app must run as a frozen PyInstaller onedir build. Locate bundled
  files with `sys._MEIPASS` when `getattr(sys, "frozen", False)`.
- **Services only:**
  - Run in the foreground, with no daemonizing or self-detaching.
  - Exit cleanly within 20 seconds on SIGINT, SIGTERM or SIGBREAK.
  - Crashes are restarted automatically, but a version that won't stay up
    for 30 seconds is rolled back and marked bad.
  - Services run as SYSTEM: don't rely on the user's profile, mapped
    drives or desktop.
- **GUI apps:** an update waits until the app is closed, so don't keep hidden
  background processes running after the window closes.

## Releasing
When a change is done: bump `version`, commit, push to `main`. That push *is*
the release. If the Release workflow fails, read its log in the Actions tab
and fix it. `HANDOVER.md` (if present) holds history from the original
Claude chat.
