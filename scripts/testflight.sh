#!/usr/bin/env bash
# Archives the iPhone app (with its widgets and the Apple Watch app) and uploads it to App Store Connect for TestFlight.
# Needs Xcode 27, a paid Apple Developer Program team in iOS/Local.xcconfig (DEVELOPMENT_TEAM) and the app's record
# in App Store Connect. Signing is automatic: Xcode creates the profiles as needed and, signed in with an account that
# may use them (Xcode ▸ Settings ▸ Accounts), signs with a cloud-managed distribution certificate.
#
#   VERSION=1.14.0       version (default: MARKETING_VERSION in iOS/Version.xcconfig)
#   BUILD=202610121530   build number (default: the current UTC time, so every upload gets a new, higher one)
#   UPLOAD=0             export build/testflight/MusicLibraryMobile.ipa instead of uploading it
#   DEVELOPMENT_TEAM=…   the team, instead of iOS/Local.xcconfig
#   ASC_KEY=path/to/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER=…
#                        sign in with an App Store Connect API key instead of the account in Xcode
#   DISTRIBUTION_CERTIFICATE=1
#                        sign everything, the archive included, with the Apple Distribution certificate in the keychain
#                        (CI: there's no development certificate there, and an App Manager API key can't use cloud
#                        signing)
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="${BUILD:-$(date -u +%Y%m%d%H%M)}"
ARCHIVE=build/MusicLibraryMobile.xcarchive
EXPORT=build/testflight

SETTINGS=(CURRENT_PROJECT_VERSION="$BUILD")
if [[ -n "${VERSION:-}" ]]; then SETTINGS+=(MARKETING_VERSION="$VERSION"); fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    SETTINGS+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
elif ! grep -qs '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' iOS/Local.xcconfig; then
    echo "error: set DEVELOPMENT_TEAM in iOS/Local.xcconfig (see iOS/Signing.xcconfig)" >&2
    exit 1
fi
if [[ "${DISTRIBUTION_CERTIFICATE:-0}" == "1" ]]; then SETTINGS+=(CODE_SIGN_IDENTITY="Apple Distribution"); fi

AUTH=()
if [[ -n "${ASC_KEY:-}" ]]; then
    AUTH=(-authenticationKeyPath "$(cd "$(dirname "$ASC_KEY")" && pwd)/$(basename "$ASC_KEY")"
          -authenticationKeyID "${ASC_KEY_ID:?set ASC_KEY_ID}" -authenticationKeyIssuerID "${ASC_ISSUER:?set ASC_ISSUER}")
fi

rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project iOS/MusicLibraryMobile.xcodeproj -scheme MusicLibraryMobile -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
    "${SETTINGS[@]}" archive -quiet

OPTIONS_DIR="$(mktemp -d)"
trap 'rm -rf "$OPTIONS_DIR"' EXIT
OPTIONS="$OPTIONS_DIR/ExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$([[ "${UPLOAD:-1}" == "1" ]] && echo upload || echo export)</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS" \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist")"
if [[ "${UPLOAD:-1}" == "1" ]]; then
    echo "Uploaded Music Library $VERSION ($BUILD). It shows up in App Store Connect ▸ TestFlight once Apple has processed it."
else
    echo "Exported $EXPORT/MusicLibraryMobile.ipa ($VERSION, $BUILD)"
fi
