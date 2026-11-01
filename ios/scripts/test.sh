#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -warnings-as-errors "$ROOT/ios/TDash/TeslaProtocol.swift" "$ROOT/ios/Tests/ProtocolTests.swift" -o "$OUT/protocol"
"$OUT/protocol"
swiftc -warnings-as-errors "$ROOT/ios/TDash/TeslaFraming.swift" "$ROOT/ios/Tests/FramingTests.swift" -o "$OUT/framing"
"$OUT/framing"
swiftc -warnings-as-errors "$ROOT/ios/TDash/TripMeter.swift" "$ROOT/ios/Tests/TripTests.swift" -o "$OUT/trip"
"$OUT/trip"
