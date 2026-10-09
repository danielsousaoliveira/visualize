#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="visualize"
helper_name="visualize-scan"
app_path="$repo_root/build/$app_name.app"
helper_build="$repo_root/build/helper"

find_developer_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -n 1
}

sign() {
    if [[ -n "$identity" ]]; then
        codesign --force --options runtime --timestamp --sign "$identity" "$@"
    else
        codesign --force --options runtime --timestamp=none --sign - "$@"
    fi
}

build_helper() {
    rm -rf "$helper_build"
    mkdir -p "$helper_build"
    (cd "$repo_root/scan-helper" && bun install --frozen-lockfile)
    for target in arm64:bun-darwin-arm64 x86_64:bun-darwin-x64; do
        (cd "$repo_root/scan-helper" && bun build src/cli.ts --compile --minify \
            --target="${target#*:}" --outfile "$helper_build/$helper_name-${target%%:*}")
    done
    lipo -create -output "$helper_build/$helper_name" \
        "$helper_build/$helper_name-arm64" "$helper_build/$helper_name-x86_64"
}

cd "$repo_root"
source "$repo_root/scripts/postgres-build-flags.sh"
swift build -c release --product "$app_name" "${postgres_flags[@]}"
binary_path="$(swift build -c release --show-bin-path)/$app_name"
build_helper

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Helpers" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/$app_name"
cp "$helper_build/$helper_name" "$app_path/Contents/Helpers/$helper_name"
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$postgres_root/COPYRIGHT" "$app_path/Contents/Resources/PostgreSQL-LICENSE.txt"
printf 'APPL????' > "$app_path/Contents/PkgInfo"

identity="${VISUALIZE_SIGNING_IDENTITY:-$(find_developer_id)}"
if [[ -n "$identity" ]]; then
    echo "Signing with: $identity"
else
    echo "No Developer ID identity found; signing ad-hoc"
fi
sign --entitlements "$repo_root/Resources/$helper_name.entitlements" \
    "$app_path/Contents/Helpers/$helper_name"
sign "$app_path"

codesign --verify --deep --strict "$app_path"
echo "Built $app_path"
