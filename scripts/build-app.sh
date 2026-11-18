#!/usr/bin/env bash
# Builds build/Notch.app (universal), signs it and optionally notarizes it.
#
#   scripts/build-app.sh                       # ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=notch-notary scripts/build-app.sh   # signed + notarized + stapled
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
BUNDLE_ID="${BUNDLE_ID:-dev.local.notch}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc, or a self-signed / Developer ID identity
NOTARY_PROFILE="${NOTARY_PROFILE:-}"  # created with: xcrun notarytool store-credentials
ARCHS="${ARCHS:-arm64 x86_64}"
# Sparkle: appcast URL and the public half of the EdDSA key (scripts/sparkle-keys.sh).
# Updates stay off while either is empty.
FEED_URL="${FEED_URL:-https://github.com/ristic583/notch-releases/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

# Always build against the Xcode SDK (the Command Line Tools SDK may not match the toolchain).
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

APP="$ROOT/build/Notch.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

echo "==> Building Swift app ($CONFIG: $ARCHS)"
BINARIES=()
for arch in $ARCHS; do
    swift build --package-path "$ROOT" -c "$CONFIG" --arch "$arch"
    BINARIES+=("$(swift build --package-path "$ROOT" -c "$CONFIG" --arch "$arch" --show-bin-path)/Notch")
done
lipo -create "${BINARIES[@]}" -output "$CONTENTS/MacOS/Notch"
# Symbol names aren't needed at run time; without them the binary is smaller.
strip "$CONTENTS/MacOS/Notch"

echo "==> Building MediaRemote bridge"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(-arch "$arch"); done
xcrun clang -dynamiclib -fobjc-arc -O2 "${ARCH_FLAGS[@]}" -mmacosx-version-min=14.2 \
    -framework Foundation -framework AppKit \
    "$ROOT/Bridge/MediaRemoteBridge.m" -o "$CONTENTS/Resources/MediaRemoteBridge.dylib"
cp "$ROOT/Bridge/notch-mediaremote.pl" "$CONTENTS/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/"
cp "$ROOT/Bridge/notch-statusline" "$CONTENTS/Resources/"
chmod +x "$CONTENTS/Resources/notch-statusline"

echo "==> Building the Claude Code hook"
xcrun clang -fobjc-arc -O2 "${ARCH_FLAGS[@]}" -mmacosx-version-min=14.2 \
    -framework Foundation \
    "$ROOT/Bridge/notch-agent-hook.m" -o "$CONTENTS/Resources/notch-agent-hook"
strip "$CONTENTS/Resources/notch-agent-hook"

echo "==> Embedding Sparkle"
SPARKLE_FRAMEWORK="$(ls -d "$ROOT"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework)"
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"

sed -e "s|\$(BUNDLE_ID)|$BUNDLE_ID|" \
    -e "s|\$(VERSION)|$VERSION|" \
    -e "s|\$(BUILD_NUMBER)|$BUILD_NUMBER|" \
    -e "s|\$(FEED_URL)|$FEED_URL|" \
    -e "s|\$(SPARKLE_PUBLIC_KEY)|$SPARKLE_PUBLIC_KEY|" \
    "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "    (no SPARKLE_PUBLIC_KEY — automatic updates stay disabled)"
fi

echo "==> Signing ($SIGN_IDENTITY)"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(--options runtime)
    # A secure timestamp is only needed for distribution (notarization).
    # A self-signed certificate keeps permissions across rebuilds without it.
    [[ "$SIGN_IDENTITY" == *"Developer ID"* ]] && SIGN_FLAGS+=(--timestamp)
fi
# Sparkle's helpers must be signed from the inside out, before the framework itself.
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$CONTENTS/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$CONTENTS/Resources/MediaRemoteBridge.dylib"
codesign "${SIGN_FLAGS[@]}" "$CONTENTS/Resources/notch-agent-hook"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT/Resources/Notch.entitlements" "$APP"
codesign --verify --strict --deep "$APP"

if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || { echo "Notarization needs a Developer ID SIGN_IDENTITY" >&2; exit 1; }
    echo "==> Notarizing"
    ZIP="$ROOT/build/Notch.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "    Notarized archive: $ZIP"
fi

echo "==> Done: $APP"
