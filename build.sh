#!/bin/bash
# Builds Encore.app (ad-hoc signed). Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=Encore.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos26.0 Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreImage -framework Security -framework CoreAudio -framework Accelerate \
  -o "$APP/Contents/MacOS/Encore"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.mzc6101.encore</string>
<key>CFBundleName</key><string>Encore</string>
<key>CFBundleDisplayName</key><string>Encore</string>
<key>CFBundleExecutable</key><string>Encore</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Encore reads the level of the music playing to animate its waveform. Audio is never recorded or stored.</string>
<key>NSAppleEventsUsageDescription</key><string>Encore reads and controls what is playing in Music, Spotify, and YouTube Music in Safari or Chrome.</string>
</dict></plist>
PLIST

if [ ! -d vendor/out ] && [ -x vendor/build-adapter.sh ]; then ./vendor/build-adapter.sh; fi
if [ -d vendor/out ]; then
  ADAPTER="$APP/Contents/Resources/mediaremote-adapter"
  mkdir -p "$ADAPTER"
  cp -R vendor/out/MediaRemoteAdapter.framework "$ADAPTER/"
  cp vendor/out/mediaremote-adapter.pl "$ADAPTER/"
  [ -f vendor/out/LICENSE ] && cp vendor/out/LICENSE "$ADAPTER/LICENSE"
fi

codesign --force --deep -s - "$APP"
echo "Built $APP"
