#!/bin/zsh
set -euo pipefail
TUCK_ROOT="${0:A:h:h}"
TUCK_SDK="${TUCK_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$TUCK_SDK" ]]; then TUCK_SDK="$(xcrun --show-sdk-path)"; fi
export SDKROOT="$TUCK_SDK"
cd "$TUCK_ROOT"
swift run -c release --scratch-path build/spm -Xswiftc -sdk -Xswiftc "$TUCK_SDK" -Xcc -isysroot -Xcc "$TUCK_SDK" TuckChecks
