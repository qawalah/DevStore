# NAS Status in the Manager: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** The DevStore window shows each Docker app's newest version and whether the NAS runs it, from Watchtower's read-only API.
**Architecture:** The updater (SYSTEM, every 10 minutes) works out the Docker versions from releases it already reads, calls Watchtower, and writes `state.nas`. The window turns that into plain-language rows and saves settings through a `set-nas` request.
**Tech Stack:** PowerShell 5.1/7 + Pester 5.7.1 (CI, Windows); Python 3.12 + pytest; plain JS/CSS.
**Spec:** `docs/superpowers/specs/2026-10-31-nas-status-design.md`

## Global Constraints
- The window never calls the network and never sees the Watchtower token.
- Watchtower is called only at `/v1/containers/details` and `/v1/status`, with `Authorization: Bearer` and a 10-second timeout.
- URL rule, on both sides: `^https?://[A-Za-z0-9.-]+(:\d{1,5})?/?$`. Token rule: 1–256 characters, no whitespace.
- Bump `windows/agent/VERSION` to 2.5.0 and `windows/manager/devstore.json` to 2.5.0.

## Review Focus
1. Watchtower unreachable or slow: the run must still finish, and the GitHub updates must still happen. That's the try/catch around the NAS step.
2. Image names with tags or digests (`:latest`, `@sha256:`), and mixed case: matching strips both and lower-cases (Pester).
3. A release published but no scan since: `pending`, not `ok` (Pester).
4. The token never reaches `state.json`, logs or the window (review plus pytest on `build_nas`).
5. Older state files without `nas`: the window shows "NAS status is off" (pytest).

### Task 1: Updater logic (Core)
Files: `windows/agent/DevStore.Core.psm1`, `windows/agent/tests/DevStore.Core.Tests.ps1`.
- Tests first:
  - `Get-DevStoreDockerRelease` picks `docker-v1.10.0` over `1.9.0`; skips drafts, prereleases, `windows-v*` and `docker-v1.2`; reads the image from the notes and lower-cases it.
  - `Get-DevStoreNasApps` covers `ok`, `pending` (stale), `pending` (scan before publish), `stopped`, `missing`, and `ghcr.io/Qawalah/werd-server@sha256:…` matching.
  - `set-nas` accepts and rejects; `Set-DevStoreConfigNas` sets and clears.
- Then implement and export. CI runs Pester. Locally there's no `pwsh`, so RED and GREEN are watched in the Self-test run.

### Task 2: Updater I/O and the run
Files: `windows/agent/DevStore.Agent.psm1`, `windows/agent/VERSION`.
- `Write-DevStoreNasToken` / `Read-DevStoreNasToken` use `nas.dat` with DPAPI LocalMachine, plus `icacls /inheritance:r` granting SYSTEM and Administrators.
- `Get-DevStoreWatchtower`.
- `set-nas` in `Invoke-DevStoreRequests`.
- The `state.nas` step in `Invoke-DevStoreUpdaterRun`, wrapped in try/catch.
- Agent tests: extend `DevStore.Agent.Tests.ps1` where it already mocks HTTP. At minimum: the `set-nas` request writes `config.nas` and calls the token writer.

### Task 3: Window
Files: `windows/manager/devstore_manager/{store.py,actions.py,api.py}`, `web/{app.js,index.html,app.css}`, `tests/test_store.py`, `tests/test_actions.py`, `devstore.json`.
- Tests first:
  - `build_nas`: off, ok, pending, stopped, missing, unreachable, token rejected, failed updates; problems appear only when configured.
  - `set_nas`: rejects bad URLs and tokens; the request body is `{"action":"set-nas","url":…,"token":…}`.
- Then implement: `view["nas"]`, NAS problems merged into the banner, `counts.nas`, the NAS menu item and page, and Settings → NAS.

### Task 4: Docs
`docs/nas-setup.md` (Watchtower API lines and the "See the NAS in DevStore" section), `docs/ROADMAP.md`, `README.md` (one line).
