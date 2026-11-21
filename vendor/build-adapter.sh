#!/bin/bash
# Builds MediaRemoteAdapter.framework (arm64 + x86_64) with clang and stages the perl script.
# Output: vendor/out/MediaRemoteAdapter.framework, vendor/out/mediaremote-adapter.pl, vendor/out/LICENSE
set -euo pipefail
cd "$(dirname "$0")"
SRC=mediaremote-adapter
OUT=out
# Upstream: https://github.com/ungive/mediaremote-adapter (BSD-3-Clause), pinned to the tested commit.
COMMIT=65714990277cb4d0415ebaf7fff6be3229362b28
if [ ! -d "$SRC" ]; then
  git clone --quiet https://github.com/ungive/mediaremote-adapter "$SRC"
  git -C "$SRC" checkout --quiet "$COMMIT"
fi
FW=$OUT/MediaRemoteAdapter.framework

rm -rf "$OUT"
mkdir -p "$FW/Versions/A/Headers" "$FW/Versions/A/Resources"

clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
  -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -I "$SRC/include" -I "$SRC/src" \
  "$SRC"/src/adapter/*.m "$SRC"/src/private/*.m "$SRC"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -o "$FW/Versions/A/MediaRemoteAdapter"

cp "$SRC/include/MediaRemoteAdapter.h" "$FW/Versions/A/Headers/"
cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -s Versions/Current/Headers "$FW/Headers"
ln -s Versions/Current/Resources "$FW/Resources"
codesign --force --deep --sign - "$FW"

cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/"
cp "$SRC/LICENSE" "$OUT/"
echo "built $FW"
