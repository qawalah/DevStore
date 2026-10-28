# Windows PC setup (one time)

The **DevStore Updater** is a scheduled task that installs and updates your
Python apps and services from GitHub Releases. The **DevStore Manager** is a
window for seeing and controlling it.

## 1. Get a GitHub token
Create a fine-grained token with **Contents → Read-only** on your `qawalah`
repos (see [phone-setup.md](phone-setup.md) step 2; the same token works).

## 2. Install the updater
1. Download this repo: GitHub → `qawalah/devstore` → **Code → Download ZIP**,
   then unzip it anywhere.
2. Open **PowerShell as administrator** (Start → type "PowerShell" →
   right-click → Run as administrator).
3. Run:
   ```powershell
   cd "$HOME\Downloads\devstore-main"      # wherever you unzipped it
   powershell -ExecutionPolicy Bypass -File .\windows\agent\Install-DevStoreAgent.ps1
   ```
4. Paste the token when asked. Input is hidden.

The installer does the following:
- creates `C:\DevStore`,
- stores the token encrypted for this PC,
- downloads WinSW (the tool that runs your Python services as real Windows
  services),
- registers the **DevStore Updater** task (runs at startup and every 10
  minutes),
- adds the **DevStore Manager** app.

Within a few minutes, **DevStore Manager** appears in the Start menu under
*DevStore*.

> The DevStore Manager is released from this repo's `main` branch. Until the
> `windows/manager` code is on `main` and its first release exists, the
> Manager shows "No windows-v release found yet." The updater keeps working,
> and you can use the commands below.

## 3. Add your apps
In **DevStore Manager**, type `qawalah/<app>` next to "Add app" and press
**Add**. Or, from an admin PowerShell:
```powershell
C:\DevStore\agent\Add-DevStoreApp.ps1 -Repo qawalah/my-app
C:\DevStore\agent\Remove-DevStoreApp.ps1 -Repo qawalah/my-app   # data is kept
```

## How updates behave
| App type | What happens on a new version |
|---|---|
| Window/tray app (`gui`) | If it's open, the update waits until you close it. The next launch is the new version. |
| Service (`service`) | Stopped, swapped, started. If the new version doesn't stay running for 30 seconds, it's rolled back automatically and that version is never retried. |

- Program files: `C:\DevStore\apps\<name>\` (replaced on update; don't store data there).
- App data: `C:\ProgramData\<name>\` (kept forever, even when an app is removed).
- Updater log: `C:\DevStore\logs\updater-YYYY-MM.log`. Service output: `C:\DevStore\logs\<name>\`.

## Maintenance
- **Token expired** (Manager shows HTTP 401): re-run the installer with
  `-NewToken`.
- **Upgrade the updater itself**: download the repo again and re-run the
  installer. Apps, state and token are kept.
- **Uninstall everything**: remove each app in the Manager, then
  `Unregister-ScheduledTask -TaskName 'DevStore Updater'` and delete
  `C:\DevStore`.
- **Antivirus/SmartScreen**: builds aren't code-signed. If Defender flags a
  build of your own app, restore it and add `C:\DevStore\apps` to its
  exclusions.
