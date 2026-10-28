#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# Extra SwiftPM arguments can select architectures, e.g. --arch arm64 --arch x86_64.
swift build -c release --product moomer "$@"
binary_dir="$(swift build -c release --show-bin-path "$@")"
app_dir="$project_dir/dist/Moomer.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/moomer" "$app_dir/Contents/MacOS/moomer"
cp Packaging/Info.plist "$app_dir/Contents/Info.plist"
rm -rf "$app_dir/Contents/Resources/Moomer_Moomer.bundle"
ditto "$binary_dir/Moomer_Moomer.bundle" "$app_dir/Contents/Resources/Moomer_Moomer.bundle"

# Ad-hoc signatures change when the binary changes; macOS may require Screen
# Recording to be reauthorized after a rebuild. A Developer ID signature keeps
# a consistent signing identity. Distribution notarization is separate.
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "$app_dir"
printf '\nBuilt %s\n' "$app_dir"
