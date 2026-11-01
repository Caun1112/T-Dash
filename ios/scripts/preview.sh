#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/ios/.build/TDashPreview.app"
mkdir -p "$APP" "$ROOT/ios/.build/previews"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -D TDASH_PREVIEW \
  -target "$ARCH-apple-ios15.0-simulator" -sdk "$SDK" \
  "$ROOT"/ios/TDash/*.swift "$ROOT/ios/Tests/PreviewApp.swift" -o "$APP/TDashPreview"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.caun.tdash.preview</string>
<key>CFBundleName</key><string>TDashPreview</string>
<key>CFBundleExecutable</key><string>TDashPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UILaunchScreen</key><dict/>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
DEVICE="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for k,v in d["devices"].items() if "iOS" in k for x in v if "iPhone" in x["name"]))')"
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.caun.tdash.preview
DATA="$(xcrun simctl get_app_container "$DEVICE" com.caun.tdash.preview data)"
for attempt in $(seq 1 45); do
  if [[ -f "$DATA/Documents/preview-complete.txt" ]]; then
    cp "$DATA/Documents/"*.png "$DATA/Documents/preview-complete.txt" "$ROOT/ios/.build/previews/"
    cat "$DATA/Documents/preview-complete.txt"
    exit 0
  fi
  sleep 2
done
echo 'Native preview failed or timed out' >&2
exit 1
