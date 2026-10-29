#!/usr/bin/env bash
# Creates the single DevStore Android signing key, used for every app.
# Run once. Then back up the .jks file and password: if they're lost, every
# app has to be uninstalled and reinstalled on the phone.
set -euo pipefail

OUT="${1:-devstore.jks}"
if [ -e "$OUT" ]; then
  echo "Refusing to overwrite existing $OUT" >&2
  exit 1
fi
command -v keytool >/dev/null || { echo "keytool not found: install a JDK (17+)" >&2; exit 1; }

GENERATED=""
if [ -n "${DEVSTORE_KEYSTORE_PASSWORD:-}" ]; then
  PASS="$DEVSTORE_KEYSTORE_PASSWORD"
elif [ ! -t 0 ]; then
  # No keyboard (for example a Claude Code session): make a strong random password.
  PASS="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  GENERATED="yes"
else
  read -r -s -p "New keystore password (min 8 chars): " PASS; echo
  read -r -s -p "Repeat password: " PASS2; echo
  [ "$PASS" = "$PASS2" ] || { echo "Passwords don't match" >&2; exit 1; }
fi
[ "${#PASS}" -ge 8 ] || { echo "Password must be at least 8 characters" >&2; exit 1; }

if [ -n "$GENERATED" ]; then SHOWN_PASS="$PASS"; else SHOWN_PASS="(the password you just typed)"; fi

keytool -genkeypair -alias devstore -keyalg RSA -keysize 4096 -validity 10950 \
  -dname "CN=DevStore" -keystore "$OUT" -storetype JKS \
  -storepass "$PASS" -keypass "$PASS" 2>/dev/null

cat <<MSG

Created $OUT (alias: devstore, valid 30 years).

Add these two secrets to EVERY app repo
(GitHub -> repo -> Settings -> Secrets and variables -> Actions -> New repository secret):

  DEVSTORE_KEYSTORE_PASSWORD = $SHOWN_PASS
  DEVSTORE_KEYSTORE_B64      = the text between the lines below

-----BEGIN DEVSTORE_KEYSTORE_B64-----
$(base64 -w0 "$OUT" 2>/dev/null || base64 "$OUT" | tr -d '\n')
-----END DEVSTORE_KEYSTORE_B64-----

BACK UP NOW: store $OUT and the password in a password manager or cloud
backup. Never commit it to git.
MSG
