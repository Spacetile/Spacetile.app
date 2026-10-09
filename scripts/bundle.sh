#!/bin/bash
# Builds build/Spacetile.app and signs it.
# Usage: bundle.sh [--dev | --release <version>]
# `--dev` also compiles in the development aids that `spacetile-ctl` can send (see
# https://spacetile.app/docs/setup/#developer-commands).
# By default signs with the first "Apple Development" identity so the Accessibility grant survives
# rebuilds (TCC then checks the certificate, not the binary hash). Falls back to ad-hoc with a warning.
# `--release` stamps the version and today's UTC release date (SpacetileReleaseDate, which the licence
# check compares with a key's update window), then signs with the first "Developer ID Application"
# identity, hardened runtime and a secure timestamp, ready for notarization. No fallback.
# Every build embeds Sparkle and its feed; only release builds check for updates on their own, so a
# self-built copy isn't swapped for a download that lacks its Accessibility grant.
set -euo pipefail
cd "$(dirname "$0")/.."
FLAGS=()
VERSION=0.1.0
RELEASE=false
while (($#)); do
  case $1 in
    --dev) FLAGS=(-Xswiftc -DSPACETILE_DEV) ;;
    --release) RELEASE=true VERSION=${2:?--release needs a version}; shift ;;
    *) echo "usage: bundle.sh [--dev | --release <version>]" >&2; exit 2 ;;
  esac
  shift
done
if $RELEASE && ((${#FLAGS[@]})); then
  echo "error: --dev and --release can't be combined" >&2
  exit 2
fi
swift build -c release --product Spacetile ${FLAGS[@]+"${FLAGS[@]}"}
APP=build/Spacetile.app
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
BIN=$(swift build -c release --show-bin-path)
cp "$BIN/Spacetile" "$APP/Contents/MacOS/Spacetile"
# The binary finds Sparkle through its @executable_path/../Frameworks runpath (Package.swift).
# Spacetile isn't sandboxed, so Sparkle's XPC services aren't needed.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
ditto "$BIN/Sparkle.framework" "$SPARKLE"
/bin/rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kodehort.spacetile</string>
<key>CFBundleName</key><string>Spacetile</string>
<key>CFBundleExecutable</key><string>Spacetile</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$(date -u +%Y%m%d%H%M)</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>SUFeedURL</key><string>https://updates.spacetile.app/appcast.xml</string>
<key>SUPublicEDKey</key><string>HAb+9WQjPD1JH3e6OoxSiAr5PXHSfB1PBa8vhWE/H3U=</string>
<key>SUEnableAutomaticChecks</key><$RELEASE/>
</dict></plist>
PLIST
$RELEASE && plutil -insert SpacetileReleaseDate -string "$(date -u +%Y-%m-%d)" "$APP/Contents/Info.plist"
# The app icon: Resources/AppIcon.icon is an Icon Composer file, compiled into the layered
# Assets.car Tahoe draws and a flat AppIcon.icns for everything else.
mkdir -p "$APP/Contents/Resources"
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$(mktemp -d)/icon.plist" >/dev/null

# App Intents metadata (the Focus filter). Xcode normally generates this; SwiftPM leaves the
# compiler's constant-value files behind, so run Apple's processor on them here.
mkdir -p "$APP/Contents/Resources"
WORK=$(mktemp -d)
rg --files --no-ignore --hidden -g '*.swiftconstvalues' .build | rg 'Release/Spacetile-p.build' | sed "s|^|$PWD/|" > "$WORK/constvalues"
ls "$PWD"/Sources/Spacetile/*.swift > "$WORK/sources"
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
  --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")" \
  --module-name Spacetile --sdk-root "$(xcrun --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family macOS --deployment-target 26.0 --target-triple arm64-apple-macos26.0 \
  --source-file-list "$WORK/sources" --swift-const-vals-list "$WORK/constvalues" >/dev/null 2>&1 \
  || echo "warning: App Intents metadata not generated; the Focus filter won't appear" >&2
/bin/rm -rf "$WORK"

if $RELEASE; then
  IDENTITY=$(security find-identity -p codesigning -v | awk '/"Developer ID Application/ {print $2; exit}')
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application identity; release builds can't fall back" >&2
    exit 1
  fi
  SIGN=(--options runtime --timestamp --sign "$IDENTITY")
else
  IDENTITY=$(security find-identity -p codesigning -v | awk '/"Apple Development/ {print $2; exit}')
  if [[ -n "$IDENTITY" ]]; then
    SIGN=(--options runtime --sign "$IDENTITY")
  else
    echo "warning: no Apple Development identity; ad-hoc signing (Accessibility must be re-granted after every build)" >&2
    SIGN=(--sign -)
  fi
fi
# Inside-out, as Sparkle documents: its helpers, the framework, then the app. Hardened runtime's
# library validation needs the framework signed by the same team as the app.
for code in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force "${SIGN[@]}" "$code"
done
codesign --force "${SIGN[@]}" --identifier com.kodehort.spacetile "$APP"
codesign -d -r- "$APP" 2>&1 | rg designated
