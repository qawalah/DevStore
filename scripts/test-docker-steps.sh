#!/usr/bin/env bash
# Runs the step scripts that .github/workflows/docker-release.yml ships, taken
# straight out of the workflow with yq, against the samples. The self-test uses
# it, so what is tested is exactly what app repos run. Needs bash, jq, yq and
# (for "smoke") Docker.
#   scripts/test-docker-steps.sh cleanup|smoke|all
set -euo pipefail
cd "$(dirname "$0")/.."
WF=.github/workflows/docker-release.yml
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# step <id>: writes that step's run script to $TMP/<id>.sh
step() {
  local s
  s=$(yq -r ".jobs.release.steps[] | select(.id == \"$1\") | .run" "$WF")
  if [ -z "$s" ] || [ "$s" = null ]; then
    echo "FAIL: step '$1' not found in $WF"
    exit 1
  fi
  printf '%s\n' "$s" > "$TMP/$1.sh"
}

test_cleanup() {
  step plan-cleanup
  # check <versions.json> <expected ids to delete>
  check() {
    VERSIONS_FILE=$1 KEEP=2 DELETE_FILE=$TMP/delete.txt bash -eo pipefail "$TMP/plan-cleanup.sh" > "$TMP/cleanup.log"
    if ! diff -u "$2" "$TMP/delete.txt"; then
      cat "$TMP/cleanup.log"
      echo "FAIL: cleanup plan for $1"
      exit 1
    fi
  }
  check samples/docker-cleanup/versions.json samples/docker-cleanup/expected-delete.txt
  check samples/docker-cleanup/empty.json /dev/null
  echo "OK cleanup plan (2 fixtures)"
}

test_smoke() {
  step smoke-test
  local broken="unhealthy no-healthcheck exits" v start took
  docker build -q -t devstore-smoke/hello samples/hello-docker > /dev/null
  for v in $broken; do
    docker build -q -t "devstore-smoke/$v" -f "samples/hello-docker-broken/Dockerfile.$v" samples/hello-docker-broken > /dev/null
  done
  # smoke <image> <log name>
  smoke() { IMAGE=$1 HEALTH_TIMEOUT=30 bash -eo pipefail "$TMP/smoke-test.sh" > "$TMP/smoke-$2.log" 2>&1; }
  if ! smoke devstore-smoke/hello hello; then
    cat "$TMP/smoke-hello.log"
    echo "FAIL: smoke test refused samples/hello-docker"
    exit 1
  fi
  for v in $broken; do
    start=$SECONDS
    if smoke "devstore-smoke/$v" "$v"; then
      cat "$TMP/smoke-$v.log"
      echo "FAIL: smoke test passed Dockerfile.$v"
      exit 1
    fi
    took=$((SECONDS - start))
    # Broken images must be refused as soon as Docker knows, not after the 30 s timeout.
    if [ "$took" -ge 20 ]; then
      cat "$TMP/smoke-$v.log"
      echo "FAIL: Dockerfile.$v was refused only after ${took}s"
      exit 1
    fi
    echo "  Dockerfile.$v refused after ${took}s"
  done
  echo "OK smoke (4 images)"
}

case "${1:-all}" in
  cleanup) test_cleanup ;;
  smoke) test_smoke ;;
  all) test_cleanup; test_smoke ;;
  *) echo "usage: $0 cleanup|smoke|all"; exit 2 ;;
esac
