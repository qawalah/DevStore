# Moving an app from a Claude chat into DevStore

Use this once per app that was developed in a Claude **chat**. Afterwards the
app lives in its own private GitHub repo, you keep developing it in **Claude
Code** sessions attached to that repo, and every version bump installs itself
on your devices.

About 30 minutes per app. Before the first app, do the one-time setup:
[phone-setup.md](../phone-setup.md) (Android) and/or
[windows-setup.md](../windows-setup.md) (Windows).

## One-time: create the Android signing key and allow workflow sharing
1. **Signing key** (Android only). In a Claude Code session on this repo,
   ask: *"Run `scripts/create-signing-key.sh` for me."* Or run it yourself
   anywhere with Java installed. It prints two values:
   `DEVSTORE_KEYSTORE_B64` and `DEVSTORE_KEYSTORE_PASSWORD`.
   - In a Claude Code session there's no keyboard, so the script makes a
     random password and prints it. **Copy both printed values** (the
     password and the long text between the BEGIN/END lines) into your
     password manager. The long text *is* the key. The cloud session's
     `devstore.jks` file disappears when the session ends, and that's fine. You'll paste the same two values into every Android app repo.
   - If they're lost, every app has to be reinstalled.
2. **Workflow sharing.** On GitHub, open `qawalah/devstore` → **Settings →
   Actions → General → Access** and choose **"Accessible from repositories
   owned by the user 'qawalah'"**. Without this, app repos can't use
   DevStore's build workflows.
3. **Merge DevStore to `main`.** App repos use `@main` of DevStore's
   workflows, so the pipeline must be on `main`.

## Per app

### Step 1: export the project from the chat
Open the Claude chat where the app was built and paste the whole prompt from
[chat-export-prompt.md](chat-export-prompt.md). Download the zip it gives you.

### Step 2: create the repo and upload
1. GitHub (web or app) → **New repository** → name it after the app (for
   example `my-app`) → **Private** → Create.
2. **Add file → Upload files** → drop the zip → **Commit changes**.

### Step 3: add secrets (Android apps only)

> **Does the app already have its own signing key** (like Werd's `werd`
> or SimDeck's `simdeck`)? Use that key instead of the DevStore key, so the
> copy on your phone keeps updating and keeps its data. See
> "Using an app's own key" below.

Repo → **Settings → Secrets and variables → Actions → New repository
secret**. Add both:
- `DEVSTORE_KEYSTORE_B64`
- `DEVSTORE_KEYSTORE_PASSWORD`

Use the same values for every app. Windows apps need no secrets.

### Step 4: let Claude Code finish it
Start a **Claude Code** session (claude.ai/code or the Claude app → Code) on
the new repo and send:

> Follow the DevStore onboarding in `qawalah/devstore` at
> `docs/handover/onboard-repo.md`, and push the result to `main`.

Releases only build from `main`, so the session needs your OK to push there.

That session unpacks the zip, adds the DevStore files, and pushes. The push
creates the first release automatically. Check the repo's **Actions** tab;
the Release run should be green.

### Step 5: install it on your device
- **Android:** uninstall the old copy (export its data first if it matters),
  then add the repo in Obtainium and install. See
  [phone-setup.md](../phone-setup.md) step 3.
- **Windows:** in DevStore Manager, add `qawalah/<app>`. If you ran the app
  by hand before, stop and delete the old copy, and move its data to
  `C:\ProgramData\<name>\` if needed.

From now on: develop in Claude Code on that repo. Every change that bumps the
version reaches your devices by itself.

## Using an app's own key

If the app is already on your phone, signed with its own keystore file, keep
using that key. Otherwise Android refuses the update, and you'd have to
uninstall the app and lose its data.

In that app's repo, add these secrets (Settings → Secrets and variables →
Actions → New repository secret):

| Secret | Value |
|---|---|
| `DEVSTORE_KEYSTORE_B64` | The app's keystore file as base64 text (see below) |
| `DEVSTORE_KEYSTORE_PASSWORD` | The keystore password |
| `DEVSTORE_KEY_ALIAS` | The key's name, for example `werd` or `simdeck` |
| `DEVSTORE_KEY_PASSWORD` | Only if the key has a different password from the keystore |

**Turning the keystore file into base64 text on Windows.** Open PowerShell
and run this, with your file's path. The text is copied to your clipboard;
paste it straight into the secret:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\werd-release.jks")) | Set-Clipboard
```

Never upload the keystore file to a repo or into a chat. If the alias is
wrong, the Release run stops and lists the key names it found.

## Shared repos (co-developing with someone else)

A repo owned by another person's account works too, with three differences:

1. **DevStore must be public.** Repos owned by other accounts can only use
   DevStore's build workflows if `qawalah/DevStore` is public. It contains
   no secrets.
2. **Use a separate signing key** for the shared app's Android build.
   Anyone who can push to a repo can read its secrets through a workflow, so
   never put your main DevStore key there. Run `scripts/create-signing-key.sh`
   again for a new key. The repo's owner adds the secrets.
3. **Access on your PC:** the owner creates a read-only token for you, and you
   add it in `DevStoreSetup.exe` with **Add as another GitHub account** (see
   `docs/windows-setup.md`).
