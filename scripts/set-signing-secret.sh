#!/bin/bash
# Stores a signing certificate from your login keychain as GitHub Actions secrets for the release workflow:
#
#   scripts/set-signing-secret.sh "Developer ID Application" DEVELOPER_ID_CERTIFICATE
#   scripts/set-signing-secret.sh "Apple Distribution" APPLE_DISTRIBUTION_CERTIFICATE
#
# The first argument is the start of the identity's name (exactly one valid identity must match), the second the
# secrets' prefix: <PREFIX>_P12 (the certificate and its private key as a base64 .p12) and <PREFIX>_PASSWORD (a new
# random password for it). Only that identity is exported, and the .p12 is checked to import the way CI imports it.
# macOS asks for your login password to allow the export. Needs `gh`, signed in with access to the repository's
# secrets. Prints no secret values; temporary files and keychains are deleted on exit.
set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

PREFIX_NAME="${1:?usage: $0 <identity name prefix> <secret prefix>}"
SECRET="${2:?usage: $0 <identity name prefix> <secret prefix>}"
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

matches="$(security find-identity -v -p codesigning | sed -n "s/^ *[0-9]*) [0-9A-F]\{40\} \"\(${PREFIX_NAME}: .*\)\"$/\1/p" | sort -u)"
if [ "$(grep -c . <<< "$matches" || true)" != 1 ]; then
    echo "error: expected one valid \"${PREFIX_NAME}\" identity in your keychain, found:" >&2
    sed 's/^/  /' <<< "${matches:-(none)}" >&2
    exit 1
fi
IDENTITY="$matches"

S="$(mktemp -d)"; chmod 700 "$S"
WORK_KC="$S/work.keychain-db"; CHECK_KC="$S/check.keychain-db"
cleanup() {
    security delete-keychain "$WORK_KC" 2>/dev/null || true
    security delete-keychain "$CHECK_KC" 2>/dev/null || true
    rm -rf "$S"
}
trap cleanup EXIT
random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true; }
# "HASH name" for every identity in a keychain, valid or not.
identities() { security find-identity "$1" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)".*$/\1 \2/p' | sort -u; }
only_identity() { [ "$(identities "$1" | wc -l | tr -d ' ')" = 1 ] && [ "$(identities "$1" | cut -d' ' -f2-)" = "$IDENTITY" ]; }

echo "1/4 Exporting identities from the login keychain (macOS asks for your login password, maybe once per key)"
pw="$(random)"
security export -k "$HOME/Library/Keychains/login.keychain-db" -t identities -f pkcs12 -P "$pw" -o "$S/all.p12" > /dev/null

echo "2/4 Keeping only ${IDENTITY}"
kcpw="$(random)"
security create-keychain -p "$kcpw" "$WORK_KC"
security unlock-keychain -p "$kcpw" "$WORK_KC"
security import "$S/all.p12" -k "$WORK_KC" -P "$pw" -A > /dev/null
rm -f "$S/all.p12"
identities "$WORK_KC" | while read -r hash name; do
    if [ "$name" != "$IDENTITY" ]; then security delete-identity -Z "$hash" "$WORK_KC"; fi
done
if ! only_identity "$WORK_KC"; then
    echo "error: couldn't isolate ${IDENTITY}; identities left:" >&2
    identities "$WORK_KC" | sed 's/^/  /' >&2
    exit 1
fi
p12pw="$(random)"
security export -k "$WORK_KC" -t identities -f pkcs12 -P "$p12pw" -o "$S/cert.p12" > /dev/null

echo "3/4 Checking it imports the way CI imports it"
security create-keychain -p "$kcpw" "$CHECK_KC"
security unlock-keychain -p "$kcpw" "$CHECK_KC"
security import "$S/cert.p12" -k "$CHECK_KC" -P "$p12pw" -T /usr/bin/codesign > /dev/null
if ! only_identity "$CHECK_KC" || ! security find-identity -v -p codesigning "$CHECK_KC" | grep -qF "\"$IDENTITY\""; then
    echo "error: the .p12 didn't import as exactly one valid ${IDENTITY} identity" >&2
    identities "$CHECK_KC" | sed 's/^/  /' >&2
    exit 1
fi

echo "4/4 Storing ${SECRET}_P12 and ${SECRET}_PASSWORD in ${REPO}"
base64 -i "$S/cert.p12" | gh secret set "${SECRET}_P12" --repo "$REPO"
printf '%s' "$p12pw" | gh secret set "${SECRET}_PASSWORD" --repo "$REPO"
echo "Done: ${IDENTITY}"
