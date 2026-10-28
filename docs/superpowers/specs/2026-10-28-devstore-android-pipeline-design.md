# DevStore Phase 1: Android Auto-Update Pipeline (Design)

Date: 2026-10-28
Status: Draft, awaiting review

## 1. Goal

When an Android app I'm developing with Claude gets a new version, it installs
itself on my phone automatically. I don't download or install APKs by hand.

### What the user said
- It's a personal "app store" for apps I develop with Claude. I'm the only user.
- My phone is Android. Phase 1 is Android only.
- Most apps were developed in Claude **chat**. APKs are downloaded and
  installed by hand today, and Android already treats each new APK as an
  update of the existing app.
- Publishing to GitHub (private) is fine. A private local (home Wi-Fi) channel
  is nice to have but not required.
- Phase 2, later: Windows companion apps and Docker server components.

### Assumptions
- All repos live under the personal GitHub account `qawalah`. It's a personal
  account, not an org, so there are no shared org-level secrets.
- From now on, apps are developed in **Claude Code** sessions attached to each
  app's repo. Claude chat can't reliably push to GitHub.
- Apps are standard Gradle Android projects that include the Gradle wrapper
  (`gradlew`).

### Success criteria
1. Pushing a version bump to an app repo's `main` branch produces a signed APK
   on a GitHub Release within about 15 minutes, with no manual steps.
2. Obtainium on the phone detects and installs that release without me opening
   a browser or file manager.
3. An existing chat-developed app can be moved into this pipeline by following
   one handover document, in under 30 minutes per app.

## 2. Architecture

```
Claude Code session ──push──▶ app repo (private, qawalah/<app>)
                                  │ push to main
                                  ▼
                       GitHub Actions: caller workflow
                                  │ uses
                                  ▼
            qawalah/devstore reusable workflow (android-release.yml)
              build → sign → read version → tag → GitHub Release (APK)
                                  │
                                  ▼
                    Obtainium on phone (polls releases,
                    installs updates in the background)
```

There's no custom server, app or database. DevStore is a repo of shared
pipeline pieces plus documentation.

## 3. Components

### 3.1 Reusable workflow: `.github/workflows/android-release.yml` (in DevStore)
A `workflow_call` workflow that app repos call. Steps:
1. Check out the caller repo and set up JDK 17 and the Android SDK.
2. `./gradlew assembleRelease`. The app's Gradle files carry **no** release
   signing config, so the output is an unsigned release APK.
3. `zipalign` and `apksigner sign` it with the shared DevStore key, decoded
   from secrets.
4. Read `versionName` and `versionCode` from the signed APK using
   `aapt2 dump badging`.
5. Compute tag `v<versionName>+<versionCode>`. **If the tag already exists,
   stop successfully without a new release.** This makes reruns safe, and a
   push without a version bump is only a build check.
6. Create the tag and a GitHub Release with asset `<repo>-<versionName>.apk`.

Inputs (all optional): `module` (default `app`), `java-version` (default `17`).
Required secrets: `DEVSTORE_KEYSTORE_B64`, `DEVSTORE_KEYSTORE_PASSWORD`.
The key alias is fixed as `devstore`, and the key password equals the
keystore password, so there are only two secrets per repo.

The workflow needs `contents: write` permission to create tags and releases.

**One-time setting:** DevStore → Settings → Actions → General → Access →
"Accessible from repositories owned by the user 'qawalah'". Without it,
private app repos can't call the reusable workflow.

### 3.2 Caller template: `templates/app-repo/.github/workflows/release.yml`
About 10 lines. It triggers on `push` to `main` and on `workflow_dispatch`,
then calls `qawalah/devstore/.github/workflows/android-release.yml@main` with
the secrets passed through. It's copied unchanged into every app repo.

### 3.3 App repo rules: `templates/app-repo/CLAUDE.md`
Instructions that every Claude Code session in an app repo reads:
- Never change `applicationId`.
- Bump `versionCode` (+1) and `versionName` for every change the user should
  receive. No bump means no release.
- Don't add a release `signingConfig`; CI signs the APK.
- Keep `gradlew` and the wrapper files committed.
- Commit and push to `main` when a change is done. That push *is* the
  release.
- Before pushing, run `./gradlew assembleRelease` locally if the environment
  allows it.

### 3.4 Signing key script: `scripts/create-signing-key.sh`
Runs once, anywhere with a JDK (for example a Claude Code session).
- Creates `devstore.jks` with alias `devstore`, RSA 4096, valid for 30 years.
- Prints the base64 value and the password to paste as the two repo secrets.
- Tells the user to save the `.jks` file and password in a password manager
  or cloud backup. **If the key is lost, every app must be uninstalled and
  reinstalled.**
- Never commits the key. `*.jks` and `*.keystore` are in `.gitignore`.

### 3.5 Handover guide: `docs/handover/README.md` plus a chat prompt
Moves an existing chat-developed app into the pipeline:

1. **In the existing Claude chat**, paste the prompt from
   `docs/handover/chat-export-prompt.md`. It asks the chat to produce **one
   zip** of the complete, buildable project: Gradle wrapper, all source and
   resources, current `applicationId`, `versionCode` and `versionName`, and a
   `HANDOVER.md` summarizing the app, its features, known issues and pending
   work from the chat. It must not include build outputs or keystores.
2. **On GitHub (web or app):** create a private repo `qawalah/<app-name>`
   and upload the single zip with "Add file → Upload files".
3. **Add the two secrets** (Settings → Secrets and variables → Actions), using
   the same values for every repo.
4. **Start a Claude Code session on the new repo** and say: "Follow the
   DevStore onboarding in `qawalah/devstore/docs/handover/onboard-repo.md`."
   That session:
   - unzips the project to the repo root and deletes the zip,
   - adds the caller workflow, `CLAUDE.md`, `HANDOVER.md` and `.gitignore`,
   - removes any release `signingConfig`,
   - bumps `versionCode`,
   - pushes. The first release is created automatically.
5. **On the phone, one time per app:** uninstall the old copy, then add the
   repo in Obtainium and install from there. This is unavoidable because the
   old APK was signed with a different key, and Obtainium must be the app's
   installer to update it silently. If the app holds data you care about,
   export it first.

`docs/handover/onboard-repo.md` holds the step-by-step instructions for the
step-4 session, so they live in one place.

### 3.6 Phone setup guide: `docs/phone-setup.md`
- Install Obtainium (from its GitHub releases or F-Droid).
- Create a fine-grained GitHub personal access token: read-only
  **Contents** on all `qawalah` repos (or only the selected app repos). Enter
  it in Obtainium → Settings → GitHub token so private repos work.
- Add each app by its repo URL and enable background updates.
- Turn on "Install unknown apps" for Obtainium.
- Note on Google's developer verification rules: already enforced in Brazil,
  Indonesia, Singapore and Thailand, with worldwide enforcement planned for
  2027. If they apply on your phone, enable the advanced sideloading option
  once in Developer Options; there's a one-time 24-hour wait. Revisit before
  2027.

### 3.7 Pipeline self-test: `samples/hello-android/` plus `.github/workflows/self-test.yml`
A minimal Android app inside DevStore. On every push to DevStore, the
self-test runs the build, sign and version-read steps against it, with a
throwaway key generated in CI and no release published. This catches
breakage in the shared workflow before it reaches app repos.

## 4. Error handling

| Failure | Result | Recovery |
|---|---|---|
| Build or compile error | Workflow fails and GitHub emails me. No release, so the phone is untouched. | Ask Claude Code to fix it from the Actions log. |
| `versionCode` not bumped | Tag exists, so the workflow passes with "no new version". | Bump and push again. |
| Missing or wrong secrets | Signing step fails with a clear message naming the secret. | Add or fix the repo secrets. |
| Reusable workflow access not enabled | Caller fails with "workflow not found". | Enable the DevStore Actions access setting (§3.1). |
| Lost signing key | Updates can't be signed with the old key. | Prevented by backups. Otherwise new key, then reinstall all apps. |
| Obtainium can't see a private repo | No update shown. | Check token expiry and scope. |

## 5. Testing
- Self-test workflow (§3.7) on every DevStore push.
- End-to-end check: create a `hello` app repo from the template, push a
  bump, confirm a Release appears, and confirm Obtainium installs it. Push a
  second bump and confirm a silent update.
- Handover check: migrate one real chat-developed app using only the docs.

## 6. Out of scope (Phase 1)
- Local/home Wi-Fi channel (nice to have, later). Obtainium can track a plain
  web link, so a local folder served over HTTP can be added as a second source
  without changing this design.
- Windows apps and Docker (Phase 2, same pattern: Velopack or a PowerShell
  updater for Windows, GHCR plus a maintained Watchtower fork for Docker).
- Dashboard across apps and devices.
- App bundles (AAB), Play Store, multiple build flavors.

## 7. Repo layout after Phase 1

```
.github/workflows/android-release.yml   reusable build/sign/release
.github/workflows/self-test.yml         validates the above on samples/
templates/app-repo/.github/workflows/release.yml
templates/app-repo/CLAUDE.md
templates/app-repo/.gitignore
scripts/create-signing-key.sh
samples/hello-android/
docs/phone-setup.md
docs/handover/README.md
docs/handover/chat-export-prompt.md
docs/handover/onboard-repo.md
README.md
```
