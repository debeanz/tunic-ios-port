#!/bin/bash
# Build libMacShim.dylib (AppKit/IOKit/... stand-ins + the SwiftUI start screen) for iOS. Needs a Mac with Xcode, or the
# GitHub Actions workflow (.github/workflows/shim.yml), which runs exactly this. No game files are involved.
#
#   tools/build_shim.sh [out_dir]          (default: build/shim)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/build/shim}"; mkdir -p "$OUT"
SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$SDK/System/Library/Frameworks/UIKit.framework" ] || { echo "no iOS SDK (install Xcode)"; exit 1; }
echo "==> iOS SDK: $SDK"
TARGET=arm64-apple-ios16.0

# the start screen is SwiftUI (shim/Launcher.swift): compiled to an object and linked into the shim
SWIFTC="$(xcrun -f swiftc)"; TC="$(dirname "$(dirname "$SWIFTC")")"
"$SWIFTC" -target $TARGET -sdk "$SDK" -O -parse-as-library -emit-object -module-name MacShimUI -wmo \
  "$HERE/shim/Launcher.swift" "$HERE/shim/StoresCore.swift" "$HERE/shim/StoresUI.swift" "$HERE/shim/GameCloud.swift" -o "$OUT/Launcher.o"

# Re-exported: frameworks the retargeted game binaries are pointed at the shim for although iOS has most of them
# (the shim adds the missing symbols) - Foundation, CoreGraphics, Security, Metal as in CyPort, plus for Tunic
# CoreVideo (CVDisplayLink), AVFoundation (two capture presets), AudioToolbox (AudioUnit: RemoteIO swap) and libiconv
# (GameAssembly's dependency that carries its _NSGetExecutablePath / _dlopen to the shim).
clang -target $TARGET -isysroot "$SDK" -dynamiclib -fobjc-arc -O2 \
  -L"$SDK/usr/lib/swift" -L"$TC/lib/swift/iphoneos" -Xlinker -rpath -Xlinker /usr/lib/swift \
  -install_name @rpath/libMacShim.dylib -compatibility_version 9999.0.0 -current_version 9999.0.0 \
  -framework Foundation -framework UIKit -framework GameController -framework QuartzCore \
  -framework Security -framework CoreGraphics -framework CoreFoundation -framework Metal -framework UniformTypeIdentifiers -framework WebKit \
  -framework AVFoundation -framework AudioToolbox -framework CoreVideo -lz -liconv \
  -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,CoreGraphics -Wl,-reexport_framework,Security -Wl,-reexport_framework,Metal \
  -Wl,-reexport_framework,CoreVideo -Wl,-reexport_framework,AVFoundation -Wl,-reexport_framework,AudioToolbox -Wl,-reexport-liconv \
  "$HERE/shim/MacShim.m" "$HERE/shim/MacShimC.c" "$HERE/shim/UnityShim.m" "$HERE/shim/UnityShimC.c" \
  "$HERE/shim/StoreCodecs.c" "$HERE/shim/third_party/lzma/LzmaDec.c" "$OUT/Launcher.o" \
  -o "$OUT/libMacShim.dylib"
rm -f "$OUT/Launcher.o"
echo "==> built $OUT/libMacShim.dylib"

# every symbol the game binaries bind to the shim must be exported by it or a library it re-exports
# (tools/shim_needs.txt is written by tools/make_ipa.py from the retargeted binaries)
nm -gU "$OUT/libMacShim.dylib" | awk '{print $NF}' > "$OUT/exports.txt"
python3 "$HERE/tools/check_shim.py" "$SDK" "$OUT/exports.txt" "$HERE/tools/shim_needs.txt"
