#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/ios/.build/TDashPreview.app"
mkdir -p "$APP" "$ROOT/ios/.build/previews"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -D TDASH_PREVIEW -D TDASH_HEADLESS \
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
# This test renders UIKit layers without SpringBoard/App installation. It tests
# the real layout code, while avoiding hosted-runner MobileInstallation hangs.
python3 - "$DEVICE" "$APP/TDashPreview" "$ROOT/ios/.build/previews" <<'PY'
import subprocess, sys
subprocess.run(['xcrun', 'simctl', 'spawn', sys.argv[1], sys.argv[2], sys.argv[3]], check=True, timeout=180)
PY
test -f "$ROOT/ios/.build/previews/preview-complete.txt"
cat "$ROOT/ios/.build/previews/preview-complete.txt"
