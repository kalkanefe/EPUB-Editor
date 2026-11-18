#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product EPUBEdit
bin_dir=$(swift build -c release --show-bin-path)
# Stage off file-provider volumes, which can attach FinderInfo during signing.
stage=$(mktemp -d)
mkdir -p build
ready=$(mktemp -d build/.epub-edit.XXXXXX)
trap 'rm -rf "$stage" "$ready"' EXIT
app="$stage/EPUB Edit.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
install -m 755 "$bin_dir/EPUBEdit" "$contents/MacOS/EPUBEdit"
install -m 644 App/Info.plist "$contents/Info.plist"
install -m 644 Artwork/AppIcon.icns "$contents/Resources/AppIcon.icns"

identity=${CODE_SIGN_IDENTITY:--}
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
output="build/EPUB Edit.app"
ditto --norsrc --noextattr "$app" "$ready/bundle"
codesign --verify --deep "$ready/bundle"
# Publish a complete bundle so obsolete files from earlier versions disappear.
swift - "$ready/bundle" "$output" <<'SWIFT'
import Darwin
let (bundle, output) = (CommandLine.arguments[1], CommandLine.arguments[2])
if renamex_np(bundle, output, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST, renamex_np(bundle, output, UInt32(RENAME_SWAP)) == 0 else {
        perror("Publishing EPUB Edit")
        exit(1)
    }
}
SWIFT
echo "Built $output"
