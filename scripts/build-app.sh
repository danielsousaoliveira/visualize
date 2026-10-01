#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_name="visualize"
app_path="$repo_root/build/$app_name.app"

find_developer_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -n 1
}

cd "$repo_root"
swift build -c release --product "$app_name"
binary_path="$(swift build -c release --show-bin-path)/$app_name"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/$app_name"
cp "$repo_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
printf 'APPL????' > "$app_path/Contents/PkgInfo"

identity="${VISUALIZE_SIGNING_IDENTITY:-$(find_developer_id)}"
if [[ -n "$identity" ]]; then
    echo "Signing with: $identity"
    codesign --force --options runtime --timestamp --sign "$identity" "$app_path"
else
    echo "No Developer ID identity found; signing ad-hoc"
    codesign --force --options runtime --timestamp=none --sign - "$app_path"
fi

codesign --verify --deep --strict "$app_path"
echo "Built $app_path"
