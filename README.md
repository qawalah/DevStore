# DevStore

A personal "app store" for apps developed with Claude. When an app gets a new
version, it installs itself on your devices:

- **Android:** each app repo builds a signed APK on GitHub and publishes it
  as a Release. **Obtainium** on the phone installs it.
- **Windows:** each Python app repo builds a standalone `.exe` with
  PyInstaller and publishes it. The **DevStore Updater** on the PC installs it:
  - **window/tray apps** update after you close them,
  - **services** restart, and roll back automatically if the new version
    fails.

  The **DevStore** window is your app store. It finds the Windows apps in
  your GitHub (and repos shared with you), shows icons and screenshots,
  installs them, keeps them updated (automatically, or when you choose),
  and updates itself.
- **Docker (NAS):** each Docker app repo builds an image on GitHub, checks
  that it starts healthy, and publishes it privately to GitHub's container
  registry (`ghcr.io`). **Watchtower** on the NAS installs it.

```
Claude Code ──push──▶ app repo ──GitHub Actions──▶ GitHub Release ──▶ Obtainium (phone)
                                       │                         └──▶ DevStore Updater (Windows PC)
                                       └──────────▶ ghcr.io image ──▶ Watchtower (NAS)
```

## Start here
1. [Phone setup](docs/phone-setup.md): Obtainium and a GitHub token.
2. [Windows setup](docs/windows-setup.md): install the updater and Manager.
3. [NAS setup](docs/nas-setup.md): ghcr.io login and Watchtower, for Docker apps.
4. [Move an app from a Claude chat](docs/handover/README.md): once per app.
5. [Roadmap](docs/ROADMAP.md): what's planned next.

## What's in this repo
| Path | What it is |
|---|---|
| `.github/workflows/android-release.yml` | Reusable workflow: build, sign and release an APK |
| `.github/workflows/windows-release.yml` | Reusable workflow: PyInstaller build and release |
| `.github/workflows/docker-release.yml` | Reusable workflow: build a Docker image, smoke-test it, push it to ghcr.io and keep the newest 2 versions |
| `.github/workflows/manager-release.yml` | Releases the DevStore Manager itself |
| `.github/workflows/self-test.yml` | Tests everything on every push (nothing is published) |
| `templates/app-repo/` | Files every Android app repo gets |
| `templates/windows-app-repo/` | Files every Windows app repo gets |
| `scripts/create-signing-key.sh` | Creates the one shared Android signing key |
| `windows/agent/` | DevStore Updater (PowerShell) + Pester tests. **Bump `windows/agent/VERSION` with every updater change**: installed updaters only self-update to a higher version |
| `windows/manager/` | DevStore Manager (Python/tkinter) + pytest tests |
| `windows/setup/` | `DevStoreSetup.exe` installer (released by `setup-release.yml`) |
| `templates/app-repo-both/` | Release workflow for a repo with both an Android app and a Windows part |
| `samples/` | Tiny apps used to test the pipelines end to end |
| `scripts/test-docker-steps.sh` | Runs the Docker workflow's smoke-test and cleanup scripts against samples (used by the self-test) |
| `docs/superpowers/` | Design spec and implementation plan |

## Versioning rule
- **Android:** a new `versionCode` makes a release (tag
  `android-v<versionName>+<versionCode>`).
- **Windows:** a new `version` in `devstore.json` makes a release (tag
  `windows-v<version>`).
- **Docker:** a new `version` in `devstore.json` publishes
  `ghcr.io/qawalah/<name>:<version>` and moves `latest`, once the image has
  turned healthy in CI (tag `docker-v<version>`, an empty Release).

Pushes without a version bump only run a build check.
