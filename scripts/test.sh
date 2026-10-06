#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="$(xcode-select -p)"
testing_flags=()

if [[ "$developer_dir" == */CommandLineTools ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    libraries="$developer_dir/Library/Developer/usr/lib"
    testing_flags=(
        -Xswiftc "-F$frameworks"
        -Xlinker "-F$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$libraries"
    )
fi

cd "$repo_root"
status=0
swift test "${testing_flags[@]}" "$@" || status=$?
(cd scan-helper && bun test) || status=$?
exit "$status"
