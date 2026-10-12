#!/bin/bash
# Selects the release Xcode named by RELEASE_XCODE (for example 27.0) on a GitHub runner, for the jobs that build the
# iPhone app. App Store Connect refuses to submit builds made with a beta Xcode, and runner images don't always say
# which of theirs are betas (the xcode-27 image's "Xcode_27.2.app" was 27.2 beta, build 27B5028f), so the version is
# pinned in .github/workflows/ci.yml instead of picking the newest. Lists every Xcode on the runner with its build,
# and fails if the pinned one isn't there.
set -euo pipefail

: "${RELEASE_XCODE:?set RELEASE_XCODE to a release Xcode version, for example 27.0}"

echo "Xcodes on this runner:"
for app in /Applications/Xcode*.app; do
    [[ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]] || continue
    echo "  $app: $("$app/Contents/Developer/usr/bin/xcodebuild" -version 2>/dev/null | tr '\n' ' ')"
done

xcode="/Applications/Xcode_${RELEASE_XCODE}.app"
if [[ ! -d "$xcode" ]]; then
    echo "::error::Xcode ${RELEASE_XCODE} isn't on this runner. Set RELEASE_XCODE in .github/workflows/ci.yml to a release (not beta) Xcode from the list above."
    exit 1
fi
sudo xcode-select -s "$xcode"
xcodebuild -version
