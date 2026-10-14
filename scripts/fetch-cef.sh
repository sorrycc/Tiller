#!/usr/bin/env bash
# Downloads CEF as README.md describes: the stock build, whose headers the Rust
# crates build against, into $CEF_PATH, and the third-party build with H.264
# and AAC, whose framework goes in the app, into ~/.local/share/cef-codecs.
# A folder already there is kept when its framework is the version below, and
# replaced otherwise, so changing a version can't leave the old framework in
# the app. The release workflow runs this.
set -euo pipefail

CEF_RS_TAG="cef-v154.2.0+154.0.28"
CEF_VERSION="154.0.28"
CODECS_URL="https://github.com/aiexkwan/aurix-cef/releases/download/cef-154.0.26-codecs/cef-154.0.26-macosarm64-slim.tar.zst"
CODECS_VERSION="154.0.26"
# The codecs build is unsigned and made by a third party: this is the archive
# that was checked. Change both together.
CODECS_SHA256="b06ad1580f92385d26bf579bf483cc82f361bfd41fa56565515dcceb0f37ebd1"
FRAMEWORK="Chromium Embedded Framework.framework"
CEF_PATH="${CEF_PATH:-$HOME/.local/share/cef}"
CODECS_DIR="$HOME/.local/share/cef-codecs"

[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# has_version <folder> <version>: the folder's framework is that CEF version,
# which its Info.plist gives with a fourth number, as in 154.0.28.0.
has_version() {
    local found
    found="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/$FRAMEWORK/Resources/Info.plist" 2>/dev/null)" || return 1
    [ "$found" = "$2" ] || [ "$found" = "$2.0" ]
}

if has_version "$CEF_PATH" "$CEF_VERSION"; then
    echo "==> CEF $CEF_VERSION already at $CEF_PATH"
else
    echo "==> exporting CEF ($CEF_RS_TAG) to $CEF_PATH"
    git clone --quiet --depth 1 --branch "$CEF_RS_TAG" https://github.com/tauri-apps/cef-rs "$TMP/cef-rs"
    cargo run --quiet --manifest-path "$TMP/cef-rs/Cargo.toml" -p export-cef-dir -- --force "$CEF_PATH"
fi

if has_version "$CODECS_DIR" "$CODECS_VERSION"; then
    echo "==> CEF $CODECS_VERSION with codecs already at $CODECS_DIR"
else
    echo "==> downloading CEF $CODECS_VERSION with codecs to $CODECS_DIR"
    curl -fsSL -o "$TMP/codecs.tar.zst" "$CODECS_URL"
    echo "$CODECS_SHA256  $TMP/codecs.tar.zst" | shasum -a 256 -c - >/dev/null
    # Another version's files would otherwise stay mixed in with these.
    rm -rf "$CODECS_DIR"
    mkdir -p "$CODECS_DIR"
    tar --use-compress-program=unzstd -xf "$TMP/codecs.tar.zst" -C "$CODECS_DIR"
fi
