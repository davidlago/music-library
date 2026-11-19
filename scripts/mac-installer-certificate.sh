#!/bin/bash
# Makes the Mac Installer Distribution certificate the Mac App Store upload is signed with ("3rd Party Mac Developer
# Installer: …", for the .pkg), adds it to your login keychain and stores it as the MAC_INSTALLER_CERTIFICATE_P12 and
# MAC_INSTALLER_CERTIFICATE_PASSWORD secrets for CI's `mac-app-store` job (docs/distribution.md ▸ The Mac App Store):
#
#   ASC_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER=… \
#       scripts/mac-installer-certificate.sh
#
# The key is made here (it never leaves this Mac except in the encrypted secret), the certificate through the App Store
# Connect API (scripts/installer-certificate.swift). It lasts a year; run this again when Apple emails that it's
# expiring (the team's certificate is shared with Jazz Discovery's: the same one can be stored in both repositories with
# scripts/set-signing-secret.sh "3rd Party Mac Developer Installer" MAC_INSTALLER_CERTIFICATE instead of making a
# new one). SECRETS=0 skips the GitHub secrets. Prints no secret values; temporary files are deleted on exit.
set -euo pipefail
trap 'echo "error: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

cd "$(dirname "$0")/.."
: "${ASC_KEY:?set ASC_KEY, ASC_KEY_ID and ASC_ISSUER (the notarizing API key)}" "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER:?set ASC_ISSUER}"
PREFIX="3rd Party Mac Developer Installer"
SECRET=MAC_INSTALLER_CERTIFICATE
OPENSSL=/usr/bin/openssl   # macOS's LibreSSL: its .p12 files import with `security`

S="$(mktemp -d)"; chmod 700 "$S"
CHECK_KC="$S/check.keychain-db"
cleanup() { security delete-keychain "$CHECK_KC" 2>/dev/null || true; rm -rf "$S"; }
trap cleanup EXIT
random() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true; }

echo "1/5 Making a key and a certificate signing request"
"$OPENSSL" req -new -newkey rsa:2048 -nodes -keyout "$S/key.pem" -out "$S/request.csr" -subj "/CN=Music Library Mac Installer" 2> /dev/null

echo "2/5 Asking Apple for the certificate"
swift scripts/installer-certificate.swift "$ASC_KEY" "$ASC_KEY_ID" "$ASC_ISSUER" "$S/request.csr" "$S/certificate.cer"

echo "3/5 Checking it imports the way CI imports it"
"$OPENSSL" x509 -inform DER -in "$S/certificate.cer" -out "$S/certificate.pem"
pw="$(random)"
"$OPENSSL" pkcs12 -export -inkey "$S/key.pem" -in "$S/certificate.pem" -out "$S/certificate.p12" -passout "pass:$pw"
rm -f "$S/key.pem"
kcpw="$(random)"
security create-keychain -p "$kcpw" "$CHECK_KC"
security unlock-keychain -p "$kcpw" "$CHECK_KC"
security import "$S/certificate.p12" -k "$CHECK_KC" -P "$pw" -T /usr/bin/productbuild > /dev/null
IDENTITY="$(security find-identity -v "$CHECK_KC" | sed -n "s/.*\"\\($PREFIX: .*\\)\"/\\1/p" | head -1)"
[ -n "$IDENTITY" ] || { echo "error: the certificate didn't import as a valid $PREFIX identity" >&2; security find-identity "$CHECK_KC" >&2; exit 1; }

echo "4/5 Adding $IDENTITY to your login keychain"
security import "$S/certificate.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pw" \
    -T /usr/bin/productbuild -T /usr/bin/xcodebuild > /dev/null

if [ "${SECRETS:-1}" = 1 ]; then
    REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
    echo "5/5 Storing ${SECRET}_P12 and ${SECRET}_PASSWORD in ${REPO}"
    base64 -i "$S/certificate.p12" | gh secret set "${SECRET}_P12" --repo "$REPO"
    printf '%s' "$pw" | gh secret set "${SECRET}_PASSWORD" --repo "$REPO"
else
    echo "5/5 Skipping the GitHub secrets (SECRETS=0)"
fi
echo "Done: $IDENTITY"
