#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Notadot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" /tmp/notadot-module-cache
SWIFTC="${SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}"
SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
"$SWIFTC" -O -sdk "$SDK" -target x86_64-apple-macosx11.0 -module-cache-path /tmp/notadot-module-cache Sources/Notadot/*.swift -o "$APP/Contents/MacOS/Notadot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
