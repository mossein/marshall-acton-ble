#!/bin/bash
# Builds the Marshall Acton III tools as macOS .app bundles.
# Requires: macOS with Xcode command-line tools (swiftc).
set -e
cd "$(dirname "$0")"

build_app() {
    local name="$1" src="$2" parse="$3"
    echo "Building $name…"
    mkdir -p "$name.app/Contents/MacOS"
    cp "plists/$name.plist" "$name.app/Contents/Info.plist"
    swiftc -O $parse "$src" -o "$name.app/Contents/MacOS/$name"
    codesign --force -s - "$name.app"
}

build_app ActonStatus status.swift "-parse-as-library"
build_app ActonProbe  probe.swift  ""

echo
echo "Done. Open the status app with:  open ./ActonStatus.app"
