# Windows PC setup (one time)

The **DevStore Updater** is a scheduled task that installs and updates your
Python apps and services from GitHub Releases. The **DevStore Manager** is a
window for seeing and controlling it.

## 1. Get a GitHub token
Create a fine-grained token with **Contents → Read-only** on your `qawalah`
repos (see [phone-setup.md](phone-setup.md) step 2; the same token works).

## 2. Install the updater

**Easy way: DevStoreSetup.exe**
1. On GitHub, open `qawalah/DevStore` → **Releases** and find the newest
   **DevStore Setup** release (tag `setup-v…`). Download `DevStoreSetup.exe`.
2. Double-click it. If Windows shows "Windows protected your PC", click
   **More info → Run anyway**. The installer isn't code-signed, which is why
   this appears.
3. Click **Yes** on the admin prompt.
4. Paste your GitHub token and click **Install**. It takes about a minute.

Run the same file again later to update DevStore or replace the token. Leave
the token empty to keep the current one.

**Manual way (PowerShell)**: if you prefer, from a downloaded copy of this
repo, in **PowerShell as administrator**:
```powershell
powershell -ExecutionPolicy Bypass -File .\windows\agent\Install-DevStoreAgent.ps1
```

Either way, the installer:
- creates `C:\DevStore`,
- stores the token encrypted for this PC,
- downloads WinSW (the tool that runs your background apps as real Windows
  services),
- registers the **DevStore Updater** task (runs at startup and every 10
  minutes),
- adds the **DevStore Manager** app.

Within a few minutes, **DevStore Manager** appears in the Start menu under
*DevStore*.

## 3. Install your apps
Open **DevStore** from the Start menu.
- **Discover** lists every repo in your GitHub that has a Windows release.
  You don't need to add them one by one. New apps appear within 10 minutes
  of their first release.
- Click an app to see its description, screenshots and activity. Click
  **Install**. No admin prompt is needed, and it's ready within a minute.
- **Installed** shows what's on this PC. Anything that needs your attention
  is listed first, in plain words.
- **Check for updates** checks right away instead of waiting up to 10
  minutes.

To give an app an icon, description and screenshots in the store, add them
to its `devstore.json` (see the app repo's `CLAUDE.md`), or just put PNGs in
the repo's `store/`, `screenshots/` or `docs/screenshots/` folder.

### Update settings
In **Settings → Updates**, choose what happens when an app has a new version.
You can override this on each app's page.
- **Automatically:** downloaded and installed by itself (the default).
- **Download, I'll install:** downloaded in the background; click **Install
  update** when it suits you.
- **Just tell me:** nothing is downloaded until you click **Update**.

### Apps shared with you
Apps in someone else's repo (where you're a collaborator) appear under
**Shared**. GitHub doesn't let your own token read another person's repos,
so:
1. The repo's **owner** creates a fine-grained token on *their* account:
   only that repo, **Contents: Read-only**. They send it to you privately.
2. Run `DevStoreSetup.exe`, paste their token, and tick **Add as another
   GitHub account**.
3. Within 10 minutes their apps appear under **Shared**. **Settings → GitHub
   accounts** lists every account DevStore uses.

### Where things are
**Settings → Where things are** opens these folders:
- Programs: `C:\DevStore\apps\<app name>\` (DevStore keeps the current and
  previous version)
- App data: `C:\ProgramData\<app name>\`, or your user folder for per-user
  settings. This is kept when an app is removed.
- DevStore's own log: `C:\DevStore\logs\`



## How updates behave
| App type | What happens on a new version |
|---|---|
| Window/tray app (`gui`) | If it's open, the update waits until you close it. The next launch is the new version. |
| Service (`service`) | Stopped, swapped, started. If the new version doesn't stay running for 30 seconds, it's rolled back automatically and that version is never retried. |

- Program files: `C:\DevStore\apps\<name>\` (replaced on update; don't store data there).
- App data: `C:\ProgramData\<name>\` (kept forever, even when an app is removed).
- Updater log: `C:\DevStore\logs\updater-YYYY-MM.log`. Service output: `C:\DevStore\logs\<name>\`.

## Maintenance
- **Token expired** (Manager shows HTTP 401): run `DevStoreSetup.exe` again
  and paste a new token.
- **Updating DevStore itself** happens automatically. A new DevStore
  Manager release also carries the updated updater scripts. If DevStore
  ever stops updating, run the newest `DevStoreSetup.exe` again; apps,
  state and token are kept.
- **Uninstall everything**: remove each app in the Manager, then
  `Unregister-ScheduledTask -TaskName 'DevStore Updater'` and delete
  `C:\DevStore`.
- **Antivirus/SmartScreen**: builds aren't code-signed. If Defender flags a
  build of your own app, restore it and add `C:\DevStore\apps` to its
  exclusions.
