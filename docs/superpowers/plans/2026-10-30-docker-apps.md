# Docker Apps on the NAS: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Docker app images to GHCR from a DevStore reusable workflow, and run Werd's server from that image on a Synology NAS that Watchtower keeps updated.

**Architecture:**
- `docker-release.yml` builds, smoke-tests (health check), pushes `:<version>` and `:latest`, tags and releases `docker-v<version>`, then prunes GHCR to 2 versions.
- The two step scripts that carry the risky logic (smoke test, cleanup plan) read only environment variables, so `self-test.yml` runs the exact shipped scripts against samples and fixtures.
- Werd's Dockerfile builds from source and pins the llama.cpp engine by checksum.

**Tech Stack:** GitHub Actions (bash, `docker`, `gh`, `jq`, `yq`), Docker/BuildKit, Go 1.26, distroless, Watchtower (`nickfedor/watchtower:1.23.2`).

**Spec:** `docs/superpowers/specs/2026-10-30-docker-apps-design.md`

## Global Constraints
- Image: `ghcr.io/<owner>/<name>`, all lower case, `linux/amd64` only, single-platform (no attestations).
- Git tag `docker-v<version>`. Release created with `gh release create --latest=false`, no assets.
- `version` must match `^\d+\.\d+\.\d+$`, and `name` must match `^[a-z0-9-]+$` (same as the Windows pipeline).
- GHCR keeps `keep` (default 2) versions with the highest `X.Y.Z` tags, plus any version tagged `latest`. Everything else is deleted, untagged versions included.
- `:latest` is pushed only after the smoke test passes. The tag is created after both pushes.
- llama.cpp b11800: `llama-b11800-bin-ubuntu-x64.tar.gz`, SHA-256 `81b133a0cd266851ebbe3eea21edf87e045d381699026a620cf1387f0cf55fe3`.
- Werd: no version bump. Never change `name`, `language` or `type` in `server/devstore.json`.
- Nothing is pushed to Werd's `main` (a push there is a release). Work goes on branch `claude/upbeat-maxwell-t2tmik` in both repos.

## Review Focus
1. **First run, package doesn't exist yet:** the GHCR list call returns 404. Cleanup must treat that as nothing to delete, not fail. Pinned by the empty-list fixture in Task 1 plus a 404 branch in Task 3.
2. **Container crashes at start:** the smoke test must report the exit right away with logs, not wait out the timeout. Pinned by `Dockerfile.exits` in Task 2.
3. **Re-run after a partial publish** (version pushed, tag missing): pushing the same tag again must be harmless, and cleanup must still see one version. GHCR reuses the digest, so this needs no extra test. Review the step order.
4. **Mixed-case owner or image** (`Qawalah`): GHCR rejects upper case, so the read step lower-cases both. Check in review.
5. **NAS CPU without AVX (J4125):** every `libggml-cpu-*.so` variant must be copied into the image, not only the build machine's best one. Pinned by a file-count check in Task 4.

---

### Task 1: Cleanup plan (pure script) and its fixture test

**Files:**
- Create: `.github/workflows/docker-release.yml` (skeleton: `on: workflow_call` with all inputs and the secret from spec §3.1; job `release`; for now only the step with `id: plan-cleanup`)
- Create: `samples/docker-cleanup/versions.json`, `samples/docker-cleanup/expected-delete.txt`, `samples/docker-cleanup/empty.json`
- Create: `scripts/test-docker-steps.sh` (the local and CI runner for Tasks 1–2)

**Interfaces:**
- Produces: the step `plan-cleanup`, which reads environment variables only.
  - `VERSIONS_FILE`: a JSON array from `GET …/packages/container/<image>/versions`, where each item has `id` and `metadata.container.tags`
  - `KEEP`: an integer
  - `DELETE_FILE`: an output path, one id per line, sorted ascending; empty when there's nothing to delete
  - stdout: a readable "keep X / delete Y" summary
- Produces: `scripts/test-docker-steps.sh cleanup` (extracts the step with `yq -r '.jobs.release.steps[] | select(.id == "plan-cleanup") | .run'`, runs it with `bash -eo pipefail`, then `diff`s against expected).

- [ ] **Step 1: Write the fixture.** `versions.json` holds these items, ids in brackets:
  - [101] `1.9.0`
  - [102] `1.10.0`, `latest`
  - [103] `1.2.0`
  - [104] no tags
  - [105] `1.8.5`
  - [106] `latest` only (a stray)
  - [107] `sha-abc` (not semver)

  With `KEEP=2`:
  - keep 102 (highest, and tagged `latest`), 101 (second highest by number, not by text) and 106 (tagged `latest`)
  - delete 103, 104, 105, 107

  `expected-delete.txt` = `103\n104\n105\n107\n`. `empty.json` = `[]`, which expects an empty output.
- [ ] **Step 2: Write `test-docker-steps.sh cleanup` and run it.** Expected: FAIL (step not found).
- [ ] **Step 3: Implement the `plan-cleanup` step.** `jq` selects semver tags with `test("^[0-9]+\\.[0-9]+\\.[0-9]+$")`, sorts by `split(".") | map(tonumber)` descending, and keeps the first `$KEEP` ids. It also keeps any id whose tags contain `latest`, and writes the rest.
- [ ] **Step 4: Run.** `bash scripts/test-docker-steps.sh cleanup` → `OK cleanup plan (2 fixtures)`.
- [ ] **Step 5: Commit.**

### Task 2: Smoke test and the test samples

**Files:**
- Modify: `.github/workflows/docker-release.yml` (add the `id: smoke-test` step)
- Create: `samples/hello-docker/{Dockerfile,devstore.json}`
- Create: `samples/hello-docker-broken/{Dockerfile.unhealthy,Dockerfile.no-healthcheck,Dockerfile.exits}`
- Modify: `scripts/test-docker-steps.sh` (add the `smoke` mode)

**Interfaces:**
- Produces: the step `smoke-test` with env `IMAGE` (a local image reference) and `HEALTH_TIMEOUT` (seconds).
  - Exit 0 on `healthy`. Non-zero, after printing `docker logs`, on: no `HEALTHCHECK` (`::error::` names it), container exited, `unhealthy`, or timeout.
  - It always removes its container.
- `hello-docker`: `FROM busybox:1.37`. `ARG VERSION=dev` is written into `/www/index.html`. `httpd -f -p 8080 -h /www` with `HEALTHCHECK CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1`. `devstore.json` is `{"name":"hello-docker","version":"1.0.0"}`.
- Broken samples, all from busybox:
  - `unhealthy`: the health command is `exit 1`, and the process sleeps
  - `no-healthcheck`: no health command, and the process sleeps
  - `exits`: has a health check, but the command is `exit 3`

- [ ] **Step 1: Add the `smoke` mode to the test script.** It builds the four images, expects `hello-docker` to pass and the three broken ones to fail, and prints `OK smoke (4 images)`.
- [ ] **Step 2: Run.** Expected: FAIL (step not found).
- [ ] **Step 3: Implement `smoke-test`.**
  - Check the health check with `docker image inspect -f '{{json .Config.Healthcheck}}'`.
  - Start with `docker run -d --health-interval=2s`.
  - Poll `State.Status` and `State.Health.Status` once a second until `HEALTH_TIMEOUT`.
  - Clean up with a `trap`.
- [ ] **Step 4: Run.** `bash scripts/test-docker-steps.sh smoke` → OK. Check that `exits` fails within seconds.
- [ ] **Step 5: Commit.**

### Task 3: The rest of the workflow, and the self-test jobs

**Files:**
- Modify: `.github/workflows/docker-release.yml`. Steps in order:
  - checkout (`fetch-depth: 0`)
  - read `devstore.json` → `APP_NAME`, `APP_VERSION`, `IMAGE_REF` (lower case), `TAG=docker-v…`
  - release-needed: `git ls-remote --exit-code --tags origin refs/tags/$TAG`, which sets `SKIP` to true or false
  - build: `docker build --platform linux/amd64 --build-arg VERSION --label org.opencontainers.image.{version,source,revision} -t $IMAGE_REF:$APP_VERSION -f … context`
  - smoke-test
  - login and push (`if: inputs.publish && env.SKIP == 'false'`)
  - tag and release
  - list versions (`if: inputs.publish`): owner type from `gh api users/<owner> --jq .type`, then `/users/` or `/orgs/`, `--paginate`, 404 → `[]`
  - plan-cleanup
  - delete: a refusal prints `::error::` naming `GHCR_CLEANUP_TOKEN`, and the step exits 1
- Modify: `.github/workflows/self-test.yml`. Add:
  - `docker-build`: `uses: ./.github/workflows/docker-release.yml` with `working-directory: samples/hello-docker` and `publish: false`
  - `docker-checks`: `runs-on: ubuntu-latest`, `bash scripts/test-docker-steps.sh all`

- [ ] **Step 1: Write the remaining steps.** The token for list and delete is `secrets.GHCR_CLEANUP_TOKEN || github.token`.
- [ ] **Step 2: Lint.** Parse both files with `yq` (valid YAML). Re-run `test-docker-steps.sh all` → both modes OK.
- [ ] **Step 3: Rehearse locally.** Run the read, build and smoke steps by hand on `samples/hello-docker` (`APP_VERSION=1.0.0`) → healthy.
- [ ] **Step 4: Commit**, then push the branch and confirm that `Self-test` → `docker-build` and `docker-checks` are green on GitHub.

### Task 4: Werd image builds from git alone

**Files (`qawalah/werd`):**
- Modify: `server/Dockerfile`, which has three stages per spec §3.3. The engine stage uses `FROM golang:1.26-alpine AS engine` (no extra base image), `ADD --checksum=sha256:<sum> <url> /tmp/llama.tar.gz`, then `tar -xzf` and `cp -a` of `llama-server libllama-server-impl.so libllama.so* libllama-common.so* libmtmd.so* libggml*.so*` into `/opt/llama`. The other tools' `*-impl.so` libraries stay out.
- Modify: `server/.dockerignore` (add `dist`)
- Delete: `server/Dockerfile.source`, `server/Dockerfile.buildx`
- Modify: `server/build.sh` (keep the tests and Windows builds; drop the Linux builds and the Docker comments)

- [ ] **Step 1: Build.** `docker build --build-arg VERSION=1.8.0 -t werd-test server` succeeds. The final stage's `RUN ["/opt/llama/llama-server","--version"]` passes.
- [ ] **Step 2: Check the engine files.** `docker run --rm --entrypoint /opt/llama/llama-server werd-test --version` exits 0. `docker create` plus `docker cp` of `/opt/llama` shows 14 `libggml-cpu-*.so` files, including `sse42` and `x64`.
- [ ] **Step 3: Smoke test.** The shipped step (`IMAGE=werd-test HEALTH_TIMEOUT=60`) → healthy. `curl /v1/info` in a container → `"version":"1.8.0"`.
- [ ] **Step 4: Check the build script.** `sh -n server/build.sh`. `go vet ./...` in `server/` if the Go toolchain allows.
- [ ] **Step 5: Commit on the Werd branch.**

### Task 5: Werd compose, caller workflow and docs

**Files (`qawalah/werd`):** `server/docker-compose.yml`, `.github/workflows/release.yml`, `CLAUDE.md`, `server/README.md`, `HANDOVER.md`. The content is spec §3.3.

- [ ] **Step 1: Edit.**
  - compose: `image: ghcr.io/qawalah/werd-server:latest`, `pull_policy: always`, label `com.centurylinklabs.watchtower.enable=true`
  - `release.yml`: `packages: write` and the `docker` job
- [ ] **Step 2: Validate.** `docker compose -f server/docker-compose.yml config` succeeds. `yq` parses `release.yml`. `grep` finds no "Dockerfile.source", "Dockerfile.buildx" or "Werd-Server-Docker" left in the docs, except where they're described as removed.
- [ ] **Step 3: Commit and push the Werd branch.** Pushing needs push access to Werd.

### Task 6: DevStore docs

**Files:** `docs/nas-setup.md` (new, spec §3.4), `README.md`, `docs/handover/onboard-repo.md`, `docs/ROADMAP.md`, `templates/app-repo-both/.github/workflows/release.yml` (a commented `docker` job).

- [ ] **Step 1: Write.**
  - The Watchtower compose in the guide uses `nickfedor/watchtower:1.23.2`, mounts `/var/run/docker.sock` and `/root/.docker:/config:ro`, and sets `DOCKER_CONFIG=/config`, `WATCHTOWER_LABEL_ENABLE=true`, `WATCHTOWER_POLL_INTERVAL=600`, `WATCHTOWER_CLEANUP=true` and `TZ=Asia/Riyadh`.
- [ ] **Step 2: Validate.** The guide's Watchtower compose passes `docker compose config`, and every relative link resolves.
- [ ] **Step 3: Commit and push.** Confirm the DevStore self-test is green.
