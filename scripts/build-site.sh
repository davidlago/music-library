#!/bin/bash
# Builds the website (site/) into build/site for GitHub Pages, with the README's screenshots
# (docs/screenshots) and the app icon converted to WebP. Needs cwebp (`brew install webp`).
# Preview: python3 -m http.server -d build/site
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/site
rm -rf "$out"
mkdir -p "$out/screenshots"
cp -R site/. "$out/"

for png in docs/screenshots/*.png; do
    cwebp -quiet -mt -q 84 "$png" -o "$out/screenshots/$(basename "$png" .png).webp"
done
cwebp -quiet -q 90 -resize 264 264 Resources/AppIcon-1024.png -o "$out/icon.webp"
# Link previews want a PNG or JPEG.
cp docs/screenshots/album.png "$out/og.png"
touch "$out/.nojekyll"

echo "Built $out ($(du -sh "$out" | cut -f1))"
