#!/bin/bash
# Builds the website (site/) into build/site for GitHub Pages, with the README's screenshots
# (docs/screenshots) and the app icon converted to WebP, and the user guide (docs/guide/*.md) rendered into
# build/site/docs by scripts/render-docs.py. Needs cwebp (`brew install webp`) and python3.
# Preview: python3 -m http.server -d build/site
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/site
rm -rf "$out"
mkdir -p "$out/screenshots"
cp -R site/. "$out/"
rm "$out/docs-template.html"

for png in docs/screenshots/*.png; do
    cwebp -quiet -mt -q 84 "$png" -o "$out/screenshots/$(basename "$png" .png).webp"
done
cwebp -quiet -q 90 -resize 264 264 Resources/AppIcon-1024.png -o "$out/icon.webp"
python3 scripts/render-docs.py "$out/docs"
# Link previews want a PNG or JPEG.
cp docs/screenshots/collection.png "$out/og.png"
touch "$out/.nojekyll"

echo "Built $out ($(du -sh "$out" | cut -f1))"
