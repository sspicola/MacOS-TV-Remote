#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/tvremote-icon.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir "$staging_dir/AppIcon.iconset"
swift "$project_dir/scripts/generate-icon.swift" "$staging_dir/AppIcon.iconset"
iconutil -c icns "$staging_dir/AppIcon.iconset" -o "$project_dir/Resources/AppIcon.icns"
