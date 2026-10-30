# DevStore: Docker Apps on the NAS (Design)

Date: 2026-10-30
Status: Approved in chat on 2026-10-30. This extends the pipeline design in
`2026-10-28-devstore-pipeline-design.md`, which listed Docker as "later, same
pattern: GHCR plus a maintained Watchtower fork".

## 1. Goal

When a Docker app I develop with Claude gets a new version, my Synology NAS
runs it without manual steps. The first app is Werd's server.

### What the user said
- The NAS is a Synology DS423+ (Intel, `linux/amd64`).
- A DevStore reusable workflow builds the app's image on GitHub and pushes it
  to `ghcr.io` with a version tag and `latest`. Old versions are cleaned up to
  stay under the free plan's 500 MB.
- The NAS runs the maintained Watchtower fork (`nickfedor/watchtower`) with a
  read-only GHCR token.
- Werd's server (`qawalah/werd`, `server/`) is the first app.
- Decisions made while designing:
  - The image is **private**.
  - GHCR keeps the **2 newest versions**. `latest` points at the newest, so
    there is one rollback step.
  - Updates are **automatic**, but `latest` only moves after CI has started
    the new image and seen its health check pass.
  - ARM NAS images are dropped. `Dockerfile.source` and `Dockerfile.buildx`
    are deleted.
  - Each Docker version gets a tag **and an empty GitHub Release**, so a
    future DevStore Manager can list Docker versions (§7).
- Later, not now: the Windows DevStore Manager shows which Docker version is
  available and which one the NAS runs.

### Assumptions
- Docker apps don't go through the Windows updater or the Manager.
- The NAS is the only Docker host.
- In a repo that has both, one `version` in `devstore.json` drives both the
  Windows release and the Docker release.

### Facts checked while designing (2026-10-30)
- **GHCR storage:** GitHub Free lists 500 MB of storage, shared by Packages,
  Actions artifacts and caches. Private packages count; public ones don't.
  GitHub's billing page also says container storage is "currently free". We
  design to 500 MB anyway.
- **GHCR tokens:** pulling a private image needs a classic personal access
  token with `read:packages`. GitHub's docs say GitHub Packages only supports
  classic tokens.
- **llama.cpp engine:** release `b11800` has
  `llama-b11800-bin-ubuntu-x64.tar.gz` (22.3 MB, SHA-256
  `81b133a0cd266851ebbe3eea21edf87e045d381699026a620cf1387f0cf55fe3`).
  - Its libraries are version 0.7.0, which matches the "0.7.0-dev" Linux
    engine named in Werd's `HANDOVER.md`.
  - It ships CPU variants down to SSE4.2, which matters because the DS423+'s
    Celeron J4125 has no AVX.
  - It needs glibc 2.34 or newer, `GLIBCXX_3.4.30`, `libgomp`, `libssl3` and
    `libcrypto`. `gcr.io/distroless/cc-debian12` has all of them (glibc 2.36).
  - No official llama.cpp Docker image exists for b11800, so the release
    archive is the source.
- **Watchtower fork:**
  - Source is `nicholas-fedor/watchtower`, image is `nickfedor/watchtower`.
    The latest release is 1.23.2 (2026-10-22). It's tested with Docker API
    1.43 and newer.
  - Settings: `WATCHTOWER_LABEL_ENABLE` with the container label
    `com.centurylinklabs.watchtower.enable=true`, `WATCHTOWER_POLL_INTERVAL`
    and `WATCHTOWER_CLEANUP`.
  - Registry login: its docs recommend mounting the folder that holds
    `docker login`'s `config.json` and setting `DOCKER_CONFIG`.
- **Windows updater:** it reads only releases whose tag matches
  `^windows-v<version>$`, among the 30 newest. `docker-v` releases don't
  affect it.

### Success criteria
1. Bumping `version` in Werd's `server/devstore.json` and pushing to `main`
   publishes `ghcr.io/qawalah/werd-server:<version>` and moves `latest`
   within about 15 minutes, but only if the image passes its health check.
2. Within about 10 minutes after that, the NAS runs the new version with its
   data intact, and `http://<nas>:8080/v1/info` shows the new version.
3. GHCR never holds more than 2 versions of an image after a successful run.
4. A NAS can be set up from `docs/nas-setup.md` in under 30 minutes.

## 2. Architecture

```
Claude Code session ──push──▶ app repo (private, qawalah/<app>)
                                  │ push to main
                                  ▼
       qawalah/devstore reusable workflow (docker-release.yml), ubuntu-latest
       read version → build image → smoke test (health check) → push
       ghcr.io/qawalah/<name>:<version> + :latest → tag + empty Release
       docker-v<version> → delete all but the 2 newest versions
                                  │
                                  ▼
       Synology NAS: Watchtower (every 10 min) sees a new :latest digest
       → pulls it → recreates the labelled container with the same settings
```

DevStore stays a repo of shared pipeline pieces plus documentation. There's
still no server, app or database of our own.

## 3. Components

### 3.1 Reusable workflow: `.github/workflows/docker-release.yml`

A `workflow_call` workflow on `ubuntu-latest`. Every step uses plain `docker`
and `gh` commands, like the other DevStore workflows.

**Inputs** (all optional):

| Input | Default | Meaning |
|---|---|---|
| `working-directory` | `.` | Folder with `devstore.json` and the Dockerfile |
| `dockerfile` | `Dockerfile` | Path relative to `working-directory` |
| `context` | `.` | Build context relative to `working-directory` |
| `image` | `name` from `devstore.json` | Image name under `ghcr.io/<owner>/` |
| `keep` | `2` | How many versions to keep on GHCR |
| `health-timeout` | `60` | Seconds the smoke test waits for "healthy" |
| `publish` | `true` | `false` = build and smoke test only (self-test) |

**Secrets:** optional `GHCR_CLEANUP_TOKEN`. When it's set, cleanup uses it.
Otherwise cleanup uses the workflow's own token. Callers pass
`secrets: inherit`.

**Permissions the caller must grant:** `contents: write` (tag and Release)
and `packages: write` (push and delete), on the `docker` job.

**Queueing:** publishing runs for one app (repo plus folder) share a
`concurrency` group with `cancel-in-progress: false`. Two quick version bumps
then publish in push order, so `latest` can't end on the older one. Build-only
runs never wait.

**Steps:**
1. **Read `devstore.json`.** `name` must match `^[a-z0-9-]+$` and `version`
   must look like `1.2.3`, the same rules as the Windows pipeline. The image is
   `ghcr.io/<owner>/<image>` in lower case.
2. **Release needed?** If `publish` is true and tag `docker-v<version>`
   already exists, write a notice ("already released, bump version to publish
   a new one") and skip to cleanup. A push without a bump costs about a
   minute.
3. **Build** with `docker build` for `linux/amd64`. The workflow passes
   `--build-arg VERSION=<version>` and sets the labels
   `org.opencontainers.image.version`, `org.opencontainers.image.source` (the
   repo URL, which links the package to the repo) and
   `org.opencontainers.image.revision`. The result is one single-platform
   image with no attestation manifests, so each release is exactly one
   package version on GHCR.
4. **Smoke test** (`id: smoke-test`):
   - The image must define a `HEALTHCHECK`, or the run fails and says so.
   - It runs the image detached with `--health-interval=2s`, keeping the
     image's own health command, and waits up to `health-timeout` seconds.
   - It passes on `healthy`. It fails if the container exits, turns
     `unhealthy` or times out.
   - The container's log is printed either way.
   - This step uses only environment variables (`IMAGE`, `HEALTH_TIMEOUT`),
     so the self-test can run the same script (§3.2).
5. **Push:** log in to `ghcr.io` with the workflow token and push
   `:<version>`. Check that the registry holds a single image manifest, not
   an index whose untagged children cleanup would delete. The build uses
   `--provenance=false --sbom=false`, because a default BuildKit build pushes
   an index. Only then tag and push `:latest`. Watchtower only follows
   `latest`, so the NAS sees nothing until this step.
6. **Tag and Release:** create `docker-v<version>` on the built commit with
   `gh release create --latest=false`. The title is
   `Docker <name> <version>` and the notes name the image and the commit. It
   has no files. `--latest=false` keeps GitHub's "Latest" badge on the app's
   own releases.
7. **Cleanup**, when `publish` is true. It also runs when step 2 found
   nothing to release, so a failed cleanup repairs itself on the next push.
   - **List** the package's versions:
     `GET /users/<owner>/packages/container/<image>/versions`, or `/orgs/…`
     for an organization.
   - **Plan** (`id: plan-cleanup`, a pure `jq` script on a versions file):
     keep the `keep` versions with the highest `X.Y.Z` tags (compared as
     numbers) and any version tagged `latest`. Delete everything else,
     including untagged versions. If the package doesn't exist yet, there's
     nothing to do.
   - **Delete** each planned version with
     `DELETE …/versions/<id>`. If GitHub refuses, the step fails with a
     message that names `GHCR_CLEANUP_TOKEN`: a classic token with
     `read:packages` and `delete:packages`. The release is already out at
     that point.

### 3.2 Self-test (in `self-test.yml`)
- **`docker-build`:** calls `docker-release.yml` on `samples/hello-docker`
  with `publish: false`. That covers the full build and the smoke test
  passing.
- **`docker-checks`:** pulls the `smoke-test` and `plan-cleanup` step scripts
  out of `docker-release.yml` with `yq`, so the test runs exactly what ships.
  - The smoke test must **fail** for `samples/hello-docker-broken`
    `Dockerfile.unhealthy` (its health command always fails),
    `Dockerfile.no-healthcheck`, and `Dockerfile.exits` (the process exits
    at once, which must be reported straight away, not after the timeout).
  - The cleanup plan must produce exactly the ids in
    `samples/docker-cleanup/expected-delete.txt` for
    `samples/docker-cleanup/versions.json`. The fixture has old versions, an
    untagged version, a version tagged `latest`, and versions where text
    order and number order differ (`1.10.0` vs `1.9.0`).
- `samples/hello-docker/` is BusyBox `httpd` serving one page, with a
  `HEALTHCHECK` that fetches it, and a `devstore.json` with `name` and
  `version`.

### 3.3 Changes in `qawalah/werd`
- **`server/Dockerfile`**, three stages:
  1. **build:** `mirror.gcr.io/library/golang:1.26-alpine` builds
     `/werd-server` from source with
     `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}"`.
  2. **engine:** `ADD --checksum=sha256:<sum>` fetches the pinned llama.cpp
     archive, which is unpacked. `llama-server`, `libllama-server-impl.so`
     and the `libllama*`, `libmtmd*` and `libggml*` libraries go to
     `/opt/llama`. The other command-line tools aren't needed. The build
     number and checksum are written out in full and must match `llamaBuild`
     in `gpu.go`, as for `prepare-llama.ps1`.
  3. **final:** `gcr.io/distroless/cc-debian12` with the server and
     `/opt/llama`. It runs `RUN ["/opt/llama/llama-server", "--version"]` so
     a missing library fails the build, not the first AI page read. The
     smoke test only starts the Go server.

  It keeps `ENV`, `VOLUME /data`, `EXPOSE 8080`, the `HEALTHCHECK` and the
  `ENTRYPOINT`, and drops the hard-coded version `LABEL`, since the workflow
  sets it. Every base image comes from Google's registries (`mirror.gcr.io`,
  `gcr.io`), as before, so Docker Hub's pull limits can't fail a release. The
  samples use `mirror.gcr.io/library/busybox` for the same reason.
- **`server/docker-compose.yml`:**
  - `build:` and `pull_policy: build` become
    `image: ghcr.io/qawalah/werd-server:latest` with `pull_policy: always`.
  - It adds the label `com.centurylinklabs.watchtower.enable=true`.
  - `network_mode: host`, `./data:/data` and the environment settings stay.
- **`server/.dockerignore`:** also ignores `dist`.
- **Deleted:** `server/Dockerfile.source` and `server/Dockerfile.buildx`.
- **`server/build.sh`:** keeps the tests and the Windows builds, and drops
  the Linux binaries.
- **`.github/workflows/release.yml`:** adds a `docker` job
  (`docker-release.yml@main`, `working-directory: server`,
  `secrets: inherit`) with `contents: write` and `packages: write` on that
  job only.
- **Docs:**
  - `CLAUDE.md` gets a Docker section: the same version bump publishes the
    image; keep the `HEALTHCHECK`; the engine pin must match `gpu.go`; no
    version in the Dockerfile or compose file.
  - `server/README.md`'s NAS section points to DevStore's NAS guide, and
    updates become automatic.
  - `HANDOVER.md`'s version-bump and release notes are updated.
- **No version bump.** `docker-v1.8.0` doesn't exist yet, so Werd's first
  push to `main` after DevStore's workflow is on `main` publishes 1.8.0.

### 3.4 NAS guide: `docs/nas-setup.md`
1. **Check Docker:** `sudo docker version` over SSH must show API 1.43 or
   newer (Container Manager on DSM 7.2 has Docker 24, which is API 1.43).
2. **Token:** create a classic token with only `read:packages` and a long
   expiry. It can read all your private packages, so keep it on the NAS
   only.
3. **Log in once** with `sudo docker login ghcr.io -u qawalah`, pasting the
   token. This writes `/root/.docker/config.json`, which both the Werd
   project and Watchtower use.
4. **Watchtower** is its own Container Manager project in
   `/volume1/docker/watchtower`, using `nickfedor/watchtower:1.23.2`:
   - it mounts `/var/run/docker.sock` and `/root/.docker` (read-only, with
     `DOCKER_CONFIG=/config`)
   - `WATCHTOWER_LABEL_ENABLE=true`, `WATCHTOWER_POLL_INTERVAL=600`,
     `WATCHTOWER_CLEANUP=true`, `TZ=Asia/Riyadh`

   It doesn't update itself. The guide says how to move to a newer version.
5. **Werd:**
   - **New install:** the folder holds only `docker-compose.yml` (and
     `data/`).
   - **Move an existing project:** back up `data/`, replace
     `docker-compose.yml`, run Project → Action → Build (or
     `docker compose up -d`), then check `/v1/info`. Delete the old
     `Dockerfile`, `dist/` and the `werd-server:1.8.0` image.
6. **Roll back:** pin `image:` to the previous version and bring the project
   up. Watchtower doesn't move a pinned tag. Go back to `latest` to resume
   updates.
7. **Troubleshooting table:**
   - `unauthorized`/`denied`: token expired or wrong scope; log in again
   - no update: label missing, or the image is unchanged
   - port 8080 taken: set `WERD_ADDR`
   - Container Manager shows the project as changed after an update:
     harmless

### 3.5 Other DevStore docs
- **`README.md`:** Docker in the diagram and in "Start here", the new
  workflow and samples in the table, and the Docker versioning rule (tag
  `docker-v<version>`).
- **`docs/handover/onboard-repo.md`:** how to add the `docker` job, plus the
  rules for a Docker app (`HEALTHCHECK`, `ARG VERSION`, data in a volume).
- **`docs/ROADMAP.md`:** Docker moves out of "Later", and "Docker versions in
  the Manager" (§7) is added.

## 4. Error handling

| Failure | Result | Recovery |
|---|---|---|
| Build error, or the engine check fails | Workflow fails, GitHub emails me. Nothing pushed. | Fix via Claude Code. |
| Image never turns healthy | Smoke test fails with the container log. Nothing pushed; NAS untouched. | Fix and push again. |
| No `HEALTHCHECK` in the image | Smoke test fails and says so. | Add one. |
| `version` not bumped | Tag exists: notice, no build, cleanup only. | Bump and push. |
| Push fails partway | No tag yet, so rerunning is safe. | Re-run the workflow. |
| Cleanup refused | Run marked failed after the release is out. | Add `GHCR_CLEANUP_TOKEN`, or delete versions by hand. Next push retries. |
| NAS token expired | Watchtower logs `unauthorized`; Werd keeps running the old version. | New token, `docker login` again. |
| New version misbehaves with real data | Watchtower has already updated. | Pin the previous version in compose (§3.4 step 6). |

## 5. Testing
- **Self-test** (§3.2) on every DevStore push: the full build and smoke test
  of `hello-docker`; the smoke test failing on the broken samples; the
  cleanup plan matching its fixture.
- **Werd image, before pushing:** build `server/Dockerfile` locally, run the
  engine check, and run the shipped smoke-test script against it.
- **End to end:**
  - Werd's first `main` push after merging publishes `werd-server:1.8.0`
    and `docker-v1.8.0`, and cleanup has nothing to delete.
  - Set up the NAS from the guide and confirm `/v1/info` shows 1.8.0.
  - The next version bump confirms Watchtower updates the NAS.
  - The third bump confirms cleanup leaves exactly 2 versions.

## 6. Out of scope
- ARM images, other Docker hosts, Docker apps on the Windows PC.
- Watchtower notifications (it supports them; add later if wanted).
- Automatic rollback on the NAS.

## 7. Later: Docker versions in the DevStore Manager
The Manager would show, per Docker app, the newest version and the version
the NAS runs. This design already provides both:
- **Newest:** the empty `docker-v<version>` Releases. They're read with the
  same token and API the updater already uses.
- **Running:** the app's own HTTP endpoint. Werd answers
  `GET /v1/info` with its version and needs no login. The image's
  `org.opencontainers.image.version` label is a fallback for a NAS-side
  helper.

## 8. Files

```
DevStore
  .github/workflows/docker-release.yml     new reusable workflow
  .github/workflows/self-test.yml          + docker-build, docker-checks
  samples/hello-docker/                    Dockerfile, devstore.json
  samples/hello-docker-broken/             Dockerfile.unhealthy, .no-healthcheck, .exits
  scripts/test-docker-steps.sh             runs the shipped step scripts on samples
  samples/docker-cleanup/                  versions.json, expected-delete.txt
  docs/nas-setup.md                        new
  docs/handover/onboard-repo.md            + Docker section
  docs/ROADMAP.md, README.md               updated
  docs/superpowers/specs/2026-10-30-docker-apps-design.md
  docs/superpowers/plans/2026-10-30-docker-apps.md

qawalah/werd
  .github/workflows/release.yml            + docker job, packages: write
  server/Dockerfile                        source build + pinned engine
  server/docker-compose.yml                GHCR image + Watchtower label
  server/.dockerignore, server/build.sh    updated
  server/Dockerfile.source, Dockerfile.buildx   deleted
  CLAUDE.md, HANDOVER.md, server/README.md updated
```
