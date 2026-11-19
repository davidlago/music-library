#!/usr/bin/env bash
# CI: imports a signing certificate and its private key into a temporary keychain that codesign and xcodebuild search,
# and prints the name of its signing identity.
#
#   scripts/import-certificate.sh "Developer ID Application"
#
# The .p12 comes base64-encoded in CERTIFICATE_P12, its password in CERTIFICATE_PASSWORD. The argument is the start
# of the identity's name. The keychain is $RUNNER_TEMP/signing.keychain-db; a second run adds to it (the Mac App Store
# upload needs the Apple Distribution and the "3rd Party Mac Developer Installer" certificates). Delete it with
# `security delete-keychain "$RUNNER_TEMP/signing.keychain-db"` when done.
set -euo pipefail

prefix="${1:?usage: $0 <identity name prefix>}"
[[ -n "${CERTIFICATE_P12:-}" ]] || { echo "::error::No certificate given for $prefix (a repository secret is missing)" >&2; exit 1; }

keychain="${RUNNER_TEMP:?}/signing.keychain-db"
password_file="$RUNNER_TEMP/signing.keychain-password"
if [[ -f "$keychain" && -f "$password_file" ]]; then
    password="$(cat "$password_file")"
else
    password="$(uuidgen)"
    (umask 077 && printf '%s' "$password" > "$password_file")
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    # Search it first, keeping the user's other keychains.
    security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
fi
security unlock-keychain -p "$password" "$keychain"
printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
security import "$RUNNER_TEMP/certificate.p12" -k "$keychain" -P "${CERTIFICATE_PASSWORD:-}" \
    -T /usr/bin/codesign -T /usr/bin/productbuild > /dev/null
rm "$RUNNER_TEMP/certificate.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" > /dev/null

# Installer certificates aren't code signing ones, so they're looked up without that policy.
policy=(-p codesigning)
[[ "$prefix" != *Installer* ]] || policy=()
identity="$(security find-identity -v ${policy[@]+"${policy[@]}"} "$keychain" | sed -n "s/.*\"\\($prefix: .*\\)\"/\\1/p" | head -1)"
[[ -n "$identity" ]] || { echo "::error::The certificate has no $prefix identity" >&2; exit 1; }
echo "$identity"
