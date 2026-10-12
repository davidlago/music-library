#!/usr/bin/env bash
# CI: imports a signing certificate and its private key into a temporary keychain that codesign and xcodebuild search,
# and prints the name of its signing identity.
#
#   scripts/import-certificate.sh "Developer ID Application"
#
# The .p12 comes base64-encoded in CERTIFICATE_P12, its password in CERTIFICATE_PASSWORD. The argument is the start
# of the identity's name. The keychain is $RUNNER_TEMP/signing.keychain-db; delete it with
# `security delete-keychain "$RUNNER_TEMP/signing.keychain-db"` when done.
set -euo pipefail

prefix="${1:?usage: $0 <identity name prefix>}"
[[ -n "${CERTIFICATE_P12:-}" ]] || { echo "::error::No certificate given for $prefix (a repository secret is missing)" >&2; exit 1; }

keychain="${RUNNER_TEMP:?}/signing.keychain-db"
password="$(uuidgen)"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$RUNNER_TEMP/certificate.p12"
security import "$RUNNER_TEMP/certificate.p12" -k "$keychain" -P "${CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign > /dev/null
rm "$RUNNER_TEMP/certificate.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" > /dev/null
# Search it first, keeping the user's other keychains.
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

identity="$(security find-identity -v -p codesigning "$keychain" | sed -n "s/.*\"\\($prefix: .*\\)\"/\\1/p" | head -1)"
[[ -n "$identity" ]] || { echo "::error::The certificate has no $prefix identity" >&2; exit 1; }
echo "$identity"
