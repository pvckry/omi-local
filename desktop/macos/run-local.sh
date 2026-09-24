#!/usr/bin/env bash
# Account-free development runner. Deliberately does not call upstream run.sh,
# seed authentication/preferences, start a backend or install in /Applications.
set -euo pipefail
umask 077
cd "$(dirname "$0")"

if [[ "${1:-}" != "--build-only" && "${1:-}" != "--launch" ]]; then
  echo 'Usage: OMI_LOCAL_SIGN_IDENTITY="Apple Development: …" ./run-local.sh --build-only|--launch [app arguments]'
  exit 2
fi
mode="$1"
shift
: "${OMI_LOCAL_SIGN_IDENTITY:?Choose an installed Apple Development or Developer ID signing identity}"
if [[ "$OMI_LOCAL_SIGN_IDENTITY" == "-" ]]; then
  echo 'Ad-hoc signing is not supported.' >&2
  exit 2
fi

app="$PWD/Desktop/.build-local/omi-local.app"
if pgrep -f "^${app}/Contents/MacOS/OmiLocal( |$)" >/dev/null; then
  echo 'Quit this Omi Local development instance before replacing its signed bundle.' >&2
  exit 1
fi
export OMI_LOCAL_BUILD=1
# Keep the upstream lockfile intact: this manifest intentionally has fewer dependencies.
saved_lock="$(mktemp)"
cp Desktop/Package.resolved "$saved_lock"
trap 'cp "$saved_lock" Desktop/Package.resolved; rm -f "$saved_lock"' EXIT
xcrun swift build --package-path Desktop --scratch-path Desktop/.build-local --product OmiLocal
bin_dir="$(xcrun swift build --package-path Desktop --scratch-path Desktop/.build-local --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/OmiLocal" "$app/Contents/MacOS/OmiLocal"
if [[ -d "$bin_dir/GRDB_GRDB.bundle" ]]; then
  cp -R "$bin_dir/GRDB_GRDB.bundle" "$app/Contents/Resources/"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>omi-local</string>
  <key>CFBundleDisplayName</key><string>Omi Local</string>
  <key>CFBundleIdentifier</key><string>com.omi.omi-local</string>
  <key>CFBundleExecutable</key><string>OmiLocal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Save microphone audio on this Mac when you start recording.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Save system audio on this Mac when you choose to include it.</string>
</dict></plist>
PLIST
codesign --force --sign "$OMI_LOCAL_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
echo "Signed local development app: $app"
if [[ "$mode" == "--launch" ]]; then
  open "$app" --args "$@"
fi
