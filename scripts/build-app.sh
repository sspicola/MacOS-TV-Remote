#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
configuration="${CONFIGURATION:-release}"
output_dir="${OUTPUT_DIR:-$project_dir/build}"
identity="${SIGNING_IDENTITY:--}"
read -r -a architectures <<< "${ARCHS:-$(uname -m)}"

case "$configuration" in debug|release) ;; *) echo "CONFIGURATION must be debug or release." >&2; exit 1 ;; esac
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
done

# Stage outside the checkout so iCloud/Finder metadata cannot invalidate signing.
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/tvremote-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
bundle="$staging_dir/TV Remote.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$output_dir"
binaries=()
for architecture in "${architectures[@]}"; do
    build_args=(--configuration "$configuration" --product TVRemote
        --force-resolved-versions --build-system native
        --triple "$architecture-apple-macosx14.0"
        -Xcc "-ffile-prefix-map=$project_dir=."
        -Xswiftc -file-prefix-map -Xswiftc "$project_dir=."
        --scratch-path "$project_dir/.build/app-$architecture")
    swift build "${build_args[@]}"
    binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
    binaries+=("$binary_dir/TVRemote")
    for resource in "$binary_dir"/*.bundle; do
        [[ -d "$resource" ]] || continue
        ditto --norsrc --noextattr "$resource" "$bundle/Contents/Resources/$(basename "$resource")"
    done
done

if [[ ${#binaries[@]} -eq 1 ]]; then
    cp "${binaries[0]}" "$bundle/Contents/MacOS/TVRemote"
else
    lipo -create "${binaries[@]}" -output "$bundle/Contents/MacOS/TVRemote"
fi
if [[ "$configuration" == release ]]; then
    strip -S "$bundle/Contents/MacOS/TVRemote"
fi
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources/"
[[ ! -f LICENSE ]] || cp LICENSE "$bundle/Contents/Resources/"
ditto --norsrc --noextattr Vendor/ItsytvCore/ThirdPartyLicenses "$bundle/Contents/Resources/Licenses"
mkdir -p "$bundle/Contents/Resources/Licenses/ItsytvCore"
cp Vendor/ItsytvCore/LICENSE "$bundle/Contents/Resources/Licenses/ItsytvCore/"
plutil -lint "$bundle/Contents/Info.plist"
xattr -cr "$bundle"
signing_args=(--force --sign "$identity" --identifier com.sam.TVRemote)
if [[ "$identity" != - ]]; then
    signing_args+=(--options runtime --timestamp)
fi
codesign "${signing_args[@]}" "$bundle"
codesign --verify --strict "$bundle"

# Replace the generated bundle as a unit; copying over an old build leaves stale files.
rm -rf "$output_dir/TV Remote.app"
ditto --norsrc --noextattr "$bundle" "$output_dir/TV Remote.app"
printf '%s\n' "$output_dir/TV Remote.app"
