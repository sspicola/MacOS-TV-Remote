#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/tvremote-release.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
archive="TV-Remote-$version-universal.zip"

if [[ -n "${NOTARYTOOL_PROFILE:-}" && "${SIGNING_IDENTITY:--}" == - ]]; then
    echo "Notarization requires a Developer ID Application signing identity." >&2
    exit 1
fi

ARCHS="arm64 x86_64" CONFIGURATION=release OUTPUT_DIR="$staging_dir" ./scripts/build-app.sh
bundle="$staging_dir/TV Remote.app"
lipo -verify_arch arm64 x86_64 "$bundle/Contents/MacOS/TVRemote"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$staging_dir/$archive"

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "$staging_dir/$archive" --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait --output-format plist > "$staging_dir/notarization.plist"
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$staging_dir/notarization.plist")"
    if [[ "$status" != Accepted ]]; then
        echo "Notarization status: $status. The archive was not published." >&2
        exit 1
    fi
    xcrun stapler staple "$bundle"
    xcrun stapler validate "$bundle"
    spctl --assess --type execute "$bundle"
    rm "$staging_dir/$archive"
    ditto -c -k --sequesterRsrc --keepParent "$bundle" "$staging_dir/$archive"
else
    echo "Packaged without notarization. See the README for first-open instructions."
fi

# Verify the distributable after extraction, away from the build tree.
mkdir "$staging_dir/extracted"
ditto -x -k "$staging_dir/$archive" "$staging_dir/extracted"
codesign --verify --strict "$staging_dir/extracted/TV Remote.app"
lipo -verify_arch arm64 x86_64 "$staging_dir/extracted/TV Remote.app/Contents/MacOS/TVRemote"
mkdir -p dist
cp "$staging_dir/$archive" "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
printf '%s\n' "$project_dir/dist/$archive"
