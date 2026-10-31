---
name: devstore-onboard
description: Use when the user says "onboard", "hand over", "integrate" or "add to DevStore" for an app, or uploads a *-handover.zip. Creates or sets up the app's own repo (qawalah/<app>), adds the DevStore release files, pushes to main straight away and watches the first release go green.
---

# DevStore onboarding (Claude Code side)

The user invoked this to move an app into DevStore **and push it
immediately**. Invoking this skill is their OK to push to the app repo's
`main` (releases only build from `main`). Don't stop to ask before pushing.
Ask only when something below says to.

Usage the user types, from a session on `qawalah/devstore` or on the app repo:

```
/devstore-onboard <app-name>
```

## 1. Find the app repo and the handover zip
1. App name: from the arguments, the zip name (`<app>-handover.zip`) or
   `HANDOVER.md`. Lowercase-with-dashes. Ask only if none of these give one.
2. Repo `qawalah/<app>`:
   - If this session is already on it, use it.
   - Otherwise call `add_repo` (owner `qawalah`, access `push`). If it
     doesn't exist, create it with the GitHub tool `create_repository`
     (`name: <app>`, `private: true`, `autoInit: true`), then `add_repo`.
     Clone it next to this repo and work there.
3. The zip, in this order: a file the user uploaded to this session, a
   `*-handover.zip` in the app repo, or in the DevStore working tree (never
   commit it to DevStore). If there is no zip but the app repo already has
   source code, onboard that code as it is. If there's nothing at all, ask
   the user to run the chat skill `devstore-handover` (see DevStore
   `docs/handover/README.md`) and upload the zip here.

## 2. Set it up
Follow DevStore `docs/handover/onboard-repo.md` sections 1 to 3 exactly
(unpack, decide every platform part, add the templates from DevStore
`templates/`). Read those files from the local DevStore checkout if there is
one, otherwise with the GitHub tools.

## 3. Push and watch
1. Commit in the app repo ("Onboard into DevStore") and
   `git push -u origin main`. If the push is refused, read
   `read_documentation` topic `github.access` and tell the user what to fix.
2. Watch the **Release** run in the app repo's Actions (GitHub tools
   `actions_list` / `get_job_logs`). Fix and push again until it's green,
   using the common failures in `onboard-repo.md` section 4.
3. Things only the user can do (you can't set repo secrets or settings).
   Say each one plainly, once:
   - **Android:** add the secrets `DEVSTORE_KEYSTORE_B64` and
     `DEVSTORE_KEYSTORE_PASSWORD` in the app repo (Settings → Secrets and
     variables → Actions), or the app's own key (README "Using an app's own
     key"). After they add them, re-run the failed Release run.
   - **"workflow not found":** DevStore's Actions access setting (README
     one-time step 2).

## 4. Report
Short and phone-friendly: the repo link, the release tag (or what's
blocking it), and the install step: Obtainium (Android), add `qawalah/<app>`
in DevStore Manager (Windows), or copy `docker-compose.yml` to the NAS
(Docker). Mention any secret found in the export so they can rotate it.
