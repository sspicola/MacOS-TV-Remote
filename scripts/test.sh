#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
developer_dir="$(xcode-select -p)"
test_args=(test --scratch-path "$project_dir/.build/test-native")

# Command Line Tools ships Swift Testing but does not expose all of its paths
# to SwiftPM. Its native runner also avoids requiring the XCTest app runner
# supplied by full Xcode. Normal Xcode installations use SwiftPM's defaults.
if [[ "$developer_dir" == */CommandLineTools ]]; then
    testing_frameworks="$developer_dir/Library/Developer/Frameworks"
    testing_macros="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ ! -d "$testing_frameworks/Testing.framework" || ! -f "$testing_macros" ]]; then
        echo "This Command Line Tools installation does not include Swift Testing." >&2
        echo "Select an Xcode or Command Line Tools installation that includes Swift Testing." >&2
        exit 1
    fi
    test_args+=(
        --build-system native --disable-xctest --enable-swift-testing
        -Xswiftc -F -Xswiftc "$testing_frameworks"
        -Xswiftc -load-plugin-library -Xswiftc "$testing_macros"
        -Xlinker "-F$testing_frameworks"
        -Xlinker -rpath -Xlinker "$testing_frameworks"
    )
fi

cd -- "$project_dir"
exec swift "${test_args[@]}" "$@"
