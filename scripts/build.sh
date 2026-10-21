#!/bin/zsh
set -euo pipefail
TUCK_ROOT="${0:A:h:h}"
TUCK_SDK="${TUCK_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$TUCK_SDK" ]]; then TUCK_SDK="$(xcrun --show-sdk-path)"; fi
export SDKROOT="$TUCK_SDK"
cd "$TUCK_ROOT"
swift build -c release --scratch-path build/spm -Xswiftc -sdk -Xswiftc "$TUCK_SDK" -Xcc -isysroot -Xcc "$TUCK_SDK"
TUCK_APP="$TUCK_ROOT/build/Tuck.app"
mkdir -p "$TUCK_APP/Contents/MacOS" "$TUCK_APP/Contents/Resources"
cp build/spm/release/Tuck "$TUCK_APP/Contents/MacOS/Tuck"
cp Resources/Info.plist "$TUCK_APP/Contents/Info.plist"
swiftc -sdk "$TUCK_SDK" -parse-as-library Sources/Tuck/TuckIcon.swift scripts/make-icon.swift -o build/make-icon
build/make-icon "$TUCK_APP/Contents/Resources"
codesign --force --sign - --options runtime "$TUCK_APP"
print "Built $TUCK_APP"
