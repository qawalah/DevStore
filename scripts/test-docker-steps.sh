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

case "${1:-all}" in
  cleanup) test_cleanup ;;
  all) test_cleanup ;;
  *) echo "usage: $0 cleanup|smoke|all"; exit 2 ;;
esac
