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
   - **Save both values and the `devstore.jks` file in your password
     manager.** You'll paste the same two values into every Android app repo.
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
