#!/bin/bash
# Generate App/Sloop/Assets.xcassets/AppIcon.appiconset from the SVG master art
# (App/Sloop/AppIcon.svg). The generated PNGs are committed so CI needs no SVG
# tooling; re-run this after editing the master art.
#
#   brew install librsvg imagemagick
#   Scripts/generate-appicon.sh
#
# Two variants come from the one master:
#   - iOS: a full-bleed opaque square (Apple masks the corners itself; the App
#     Store rejects alpha in the 1024 marketing icon), so the master's rounded
#     corners are flattened to rx=0 and the alpha channel stripped.
#   - macOS: the system does NOT mask, so the art keeps its rounded corners and
#     is scaled into the 824pt content box of Apple's 1024pt icon grid, with the
#     template's soft drop shadow.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=App/Sloop/AppIcon.svg
OUT=App/Sloop/Assets.xcassets/AppIcon.appiconset
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

# --- iOS: square, opaque, 1024. ---------------------------------------------
sed 's/rx="228"/rx="0"/g' "$SRC" > "$TMP/ios.svg"
rsvg-convert -w 1024 -h 1024 "$TMP/ios.svg" > "$TMP/ios.png"
magick "$TMP/ios.png" -alpha off PNG24:"$OUT/AppIcon-iOS-1024.png"

# --- macOS: rounded master in the 824/1024 icon grid, with shadow. ----------
# 824/1024 = 0.8046875; (1024-824)/2 = 100. The master's rx=228 scales to ~184,
# matching Apple's 185.4pt template radius.
# The shadow is a separate blurred rect behind the art (not a filter on the art
# itself — librsvg rasterizes filtered content coarsely, which bands the
# gradients).
{
  echo '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
  echo '  <filter id="icnshadow" x="-15%" y="-15%" width="130%" height="130%">'
  echo '    <feGaussianBlur stdDeviation="12"/>'
  echo '  </filter>'
  echo '  <rect x="100" y="110" width="824" height="824" rx="184" fill="#000000" opacity="0.35" filter="url(#icnshadow)"/>'
  echo '  <g transform="translate(100 100) scale(0.8046875)">'
  sed '1d;$d' "$SRC"
  echo '  </g>'
  echo '</svg>'
} > "$TMP/macos.svg"

for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$px" -h "$px" "$TMP/macos.svg" > "$TMP/mac-$px.png"
done
cp "$TMP/mac-16.png"   "$OUT/AppIcon-macOS-16.png"
cp "$TMP/mac-32.png"   "$OUT/AppIcon-macOS-16@2x.png"
cp "$TMP/mac-32.png"   "$OUT/AppIcon-macOS-32.png"
cp "$TMP/mac-64.png"   "$OUT/AppIcon-macOS-32@2x.png"
cp "$TMP/mac-128.png"  "$OUT/AppIcon-macOS-128.png"
cp "$TMP/mac-256.png"  "$OUT/AppIcon-macOS-128@2x.png"
cp "$TMP/mac-256.png"  "$OUT/AppIcon-macOS-256.png"
cp "$TMP/mac-512.png"  "$OUT/AppIcon-macOS-256@2x.png"
cp "$TMP/mac-512.png"  "$OUT/AppIcon-macOS-512.png"
cp "$TMP/mac-1024.png" "$OUT/AppIcon-macOS-512@2x.png"

# --- Contents.json: iOS single-size (Xcode 14+) + the full macOS set. -------
cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon-iOS-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    { "filename" : "AppIcon-macOS-16.png",     "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "AppIcon-macOS-16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "AppIcon-macOS-32.png",     "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "AppIcon-macOS-32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "AppIcon-macOS-128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "AppIcon-macOS-128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "AppIcon-macOS-256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "AppIcon-macOS-256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "AppIcon-macOS-512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "AppIcon-macOS-512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

cat > App/Sloop/Assets.xcassets/Contents.json <<'JSON'
{
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "AppIcon set written to $OUT"
