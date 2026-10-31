# DevStore: NAS Status in the Manager (Design)

Date: 2026-10-31
Status: Approved in chat on 2026-10-31 ("go ahead"). This builds on
`2026-10-30-docker-apps-design.md` §7.

## 1. Goal
The DevStore window on the PC shows, for each Docker app, the newest
published version and whether the NAS runs it. The main question it answers
is "has the NAS pulled the latest image yet?"

### What the user said
- DevStore on Windows should read Watchtower and the Docker versions.
- Minimal questions. Build straight through; pause only before merging,
  because merging publishes a new Manager to the PC.

### Decisions
- **The updater does all network calls**, as it does for GitHub. Every 10
  minutes it calls Watchtower and writes the result to `state.json`. The
  window only reads files and never sees the Watchtower token.
- **No version numbers come from the NAS.** Watchtower's API doesn't report
  them. The running version is inferred:
  - Watchtower last scanned after the newest `docker-v` release was
    published, and the container isn't `stale`: the NAS runs that version.
  - Otherwise the NAS is waiting for Watchtower, or the update failed.
- **Only read-only Watchtower endpoints are turned on:** `containers` and
  `metrics` (`/v1/status`). Nothing can start an update from the PC.

## 2. Data flow
```
GitHub releases (already read for Discover) ─┐
                                              ├─▶ updater (SYSTEM, every 10 min) ─▶ state.json "nas" ─▶ window: NAS page
Watchtower API on the NAS ───────────────────┘      token in nas.dat (encrypted)
  GET /v1/containers/details, GET /v1/status
```

## 3. Updater (`windows/agent`, VERSION 2.5.0)

### 3.1 Pure logic (`DevStore.Core.psm1`, Pester-tested)
- **`Get-DevStoreDockerRelease -Releases`:** the newest non-draft,
  non-prerelease `docker-v<X.Y.Z>` release, compared as numbers. Returns
  `@{ version; tag; publishedAt; image }`, or `$null`.
  - `image` is the `ghcr.io/...` reference in the release notes, with its
    `:<version>` cut off, in lower case. The docker workflow writes it in
    the notes as `` Image `ghcr.io/o/n:1.2.3` ``.
- **`Get-DevStoreNasApps -Docker -Containers -LastScan`:** for each repo
  with a Docker release, finds the Watchtower container whose image, minus
  its tag or digest and in lower case, equals the release image. Statuses:

  | Status | When |
  |---|---|
  | `missing` | no such container on the NAS |
  | `stopped` | the container isn't running |
  | `pending` | it's `stale`, or Watchtower hasn't scanned since the release was published |
  | `ok` | otherwise; the NAS runs `version` |

  Each entry is `@{ repo; name; latest; publishedAt; container; status }`.
- **`ConvertFrom-DevStoreRequest`** accepts
  `@{ action = 'set-nas'; url; token }`.
  - `url` is empty (turn NAS status off) or matches
    `^https?://[A-Za-z0-9.-]+(:\d{1,5})?/?$`.
  - `token` is empty or 1–256 characters with no spaces or control
    characters. An empty token with a URL keeps the stored token.
- **`Set-DevStoreConfigNas -Config -Url`** sets `config.nas.watchtower`, or
  removes `nas` when the URL is empty.

### 3.2 Doing (`DevStore.Agent.psm1`)
- **`Write-DevStoreNasToken` / `Read-DevStoreNasToken`:** `<Root>\nas.dat`,
  DPAPI machine scope like `token.dat`. Inheritance is removed and access
  is limited to SYSTEM and Administrators, so normal users can't read it.
- **`Get-DevStoreWatchtower -Url -Token`:** sends both GETs with
  `Authorization: Bearer`, with a 10-second timeout each. A 401 says the
  token was rejected.
- **The run:**
  - The request handler applies `set-nas`.
  - After the catalog step, `Get-DevStoreDockerRelease` runs over the
    release cache, which covers every repo the tokens can read, including
    Docker-only repos.
  - When `config.nas.watchtower` is set, the updater calls Watchtower and
    writes `state.nas`:
    ```
    { url, checked, lastScan, failed, error, apps: { <repo>: {name, latest, publishedAt, container, status} } }
    ```
  - When Watchtower can't be reached, `error` says so, and the apps list
    still carries the newest versions.
  - Without a NAS setting, `state.nas` only holds the newest versions, so
    the window can say "set up NAS status".

## 4. Window (`windows/manager`, 2.5.0)
- **`store.build_nas(state, now)`**, pytest-tested, produces:
  - `configured` and `url`
  - a header (kind, title, sub), for example "Watchtower checked 4 min
    ago", "Can't reach Watchtower: …" or "Last check: 1 update failed"
  - rows `{repo, name, latest, kind, text}`:

    | status | Row text |
    |---|---|
    | `ok` | "Running the latest (1.8.0)" |
    | `pending` | "Update to 1.9.0 waiting for Watchtower" |
    | `stopped` | "Stopped on the NAS" |
    | `missing` | "Not running on the NAS" |
    | Watchtower unreachable | "Unknown: can't reach the NAS" |

  NAS problems also go in the problems banner, but not when NAS status is
  off.
- **`actions.set_nas(url, token)`** validates the input like the updater
  does and writes a `set-nas` request.
- **`api.set_nas`** passes the call through.
- **UI:**
  - A **NAS** item in the left menu, with a count of NAS problems.
  - The **NAS page** shows the header and one row per Docker app.
  - **Settings → NAS:** a Watchtower address field, a token field (always
    shown empty, and an empty token keeps the stored one), Save, and Turn
    off.

## 5. NAS change (`docs/nas-setup.md`)
The Watchtower compose file gains:
- `ports: ["8081:8080"]`
- `WATCHTOWER_HTTP_API_ENDPOINTS=containers,metrics`
- `WATCHTOWER_HTTP_API_TOKEN=<long random>`

There's a new section, "See the NAS in DevStore", with the steps for
Settings → NAS.

## 6. Error handling
| Case | Shown |
|---|---|
| NAS off, asleep or on another network | Header "Can't reach Watchtower at <url>"; rows "Unknown"; one problem banner |
| Token wrong | Header "Watchtower rejected the token. Enter it again in Settings → NAS." |
| Watchtower API not enabled | Same as unreachable; the header names the setting to add |
| Image on the NAS but no `docker-v` release | Not listed. Only DevStore Docker apps are shown |
| Release published, Watchtower not scanned yet | `pending` |

## 7. Testing
- **Pester:** `Get-DevStoreDockerRelease` (newest by number, skips drafts,
  prereleases and other tags, reads the image),
  `Get-DevStoreNasApps` (each status, tag and digest stripped, case),
  `set-nas` validation, `Set-DevStoreConfigNas`.
- **pytest:** `build_nas` (every status, unreachable, rejected token,
  not configured, problems), `actions.set_nas` validation and request
  body.
- **Real NAS:** after merging, the user enables the API, enters the address
  and token, and checks that Werd shows "Running the latest (1.8.0)".

## 8. Out of scope
Starting updates from the PC, exact version numbers for older images, and
showing containers that aren't DevStore apps.
