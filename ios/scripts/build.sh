#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/ios/.build"
PACKAGE="$ROOT/ios/packages"
VERSION="${TDASH_VERSION:-0.1.1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][a-zA-Z0-9.]+)?$ ]] || { echo 'Invalid version' >&2; exit 1; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p "$OUT" "$PACKAGE"
for ARCH in arm64 arm64e; do
    xcrun --sdk iphoneos clang -arch "$ARCH" -isysroot "$SDK" -miphoneos-version-min=15.0 \
        -fobjc-arc -O2 -c "$ROOT/ios/TDash/Bootstrap.m" -o "$OUT/Bootstrap-$ARCH.o"
    xcrun --sdk iphoneos swiftc -swift-version 5 -target "$ARCH-apple-ios15.0" -sdk "$SDK" \
        -O -whole-module-optimization -emit-library -module-name TDash \
        "$ROOT"/ios/TDash/*.swift "$OUT/Bootstrap-$ARCH.o" \
        -Xlinker -install_name -Xlinker @rpath/TDash.dylib \
        -Xlinker -rpath -Xlinker /usr/lib/swift \
        -Xlinker -rpath -Xlinker /var/jb/usr/lib \
        -o "$OUT/TDash-$ARCH.dylib"
done
xcrun lipo -create "$OUT/TDash-arm64.dylib" "$OUT/TDash-arm64e.dylib" -output "$OUT/TDash.dylib"
# Apple codesign signs every fat slice, including the current arm64e ABI subtype.
# Homebrew ldid can leave that slice unsigned while returning success.
codesign --force --sign - --timestamp=none --identifier com.caun.tdash.amap "$OUT/TDash.dylib"
STAGE="$(mktemp -d "$OUT/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
LIB="$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
DOC="$STAGE/var/jb/usr/share/doc/com.caun.tdash.amap"
mkdir -p "$STAGE/DEBIAN" "$LIB" "$DOC"
sed "s/^Version:.*/Version: $VERSION/" "$ROOT/ios/control" > "$STAGE/DEBIAN/control"
cp "$OUT/TDash.dylib" "$ROOT/ios/TDash/TDash.plist" "$LIB/"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/ios/README.md" "$DOC/"
chmod 755 "$LIB/TDash.dylib"
chmod 644 "$STAGE/DEBIAN/control" "$LIB/TDash.plist" "$DOC/"*
DEB="$PACKAGE/com.caun.tdash.amap_${VERSION}_iphoneos-arm64.deb"
COPYFILE_DISABLE=1 dpkg-deb -Zxz --root-owner-group --build "$STAGE" "$DEB"
python3 "$ROOT/ios/scripts/verify-package.py" "$DEB"
(cd "$PACKAGE" && shasum -a 256 "$(basename "$DEB")") > "$DEB.sha256"
echo "$DEB"
