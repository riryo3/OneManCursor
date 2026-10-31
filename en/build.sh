#!/bin/sh
# Build OneManCursor.app
# Usage: sh build.sh
set -e
cd "$(dirname "$0")"

APP="OneManCursor.app"
# Show the build number from the source (so it's obvious which version is being built)
BUILD_TAG=$(grep -o '"Build [0-9-]*"' main.swift | head -1 | tr -d '"')
echo "Build number: $BUILD_TAG"
# Trailing number to burn into the icon (e.g. 32)
BUILD_NUM=$(printf '%s' "$BUILD_TAG" | awk -F- '{print $NF}')
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Generate the icon (make_icon.swift → iconset → icns)
swiftc make_icon.swift -o /tmp/onemancursor_make_icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
/tmp/onemancursor_make_icon "$ICONSET" "$BUILD_NUM"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Main binary (universal binary for both Apple Silicon and Intel)
# main.swift = swipe/sharing (from FinderSwipe), cursor.swift = cursor display (from AlwaysCursor)
swiftc -O -framework Cocoa -framework ApplicationServices -framework IOKit -framework ServiceManagement -framework UniformTypeIdentifiers \
    -target arm64-apple-macos13.0 main.swift cursor.swift -o /tmp/OneManCursor-arm64
swiftc -O -framework Cocoa -framework ApplicationServices -framework IOKit -framework ServiceManagement -framework UniformTypeIdentifiers \
    -target x86_64-apple-macos13.0 main.swift cursor.swift -o /tmp/OneManCursor-x86_64
lipo -create /tmp/OneManCursor-arm64 /tmp/OneManCursor-x86_64 -output "$APP/Contents/MacOS/OneManCursor"
cp Info.plist "$APP/Contents/Info.plist"
# Signing: use an Apple Development certificate if there is one (rebuilds are then treated as the same app,
# which keeps permissions and Gatekeeper checks stable). Fall back to ad-hoc signing only if none exists
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$SIGN_ID" ]; then
    echo "Signing: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "Signing: ad-hoc (no Apple Development certificate found)"
    codesign --force --deep --sign - "$APP"
fi
echo "Done: $APP / $BUILD_TAG"

# For distribution: sh build.sh dist
# Strip the personal signature (the certificate name contains the Apple ID email) and replace it with an ad-hoc signature,
# then create the distribution zip. The personal $APP is left as is
if [ "$1" = "dist" ]; then
    rm -rf dist
    mkdir -p dist
    cp -R "$APP" "dist/$APP"
    # For distribution, restore the standard icon (no build number). The numbered icon from regular builds
    # is for telling development versions apart, so it is not included in stable releases
    DIST_ICONSET="$(mktemp -d)/AppIcon.iconset"
    /tmp/onemancursor_make_icon "$DIST_ICONSET"
    iconutil -c icns "$DIST_ICONSET" -o "dist/$APP/Contents/Resources/AppIcon.icns"
    codesign --force --deep --sign - "dist/$APP"
    if codesign -dv "dist/$APP" 2>&1 | grep -q "Apple Development"; then
        echo "Error: the distribution app still has an Apple Development signature"
        exit 1
    fi
    (cd dist && ditto -c -k --keepParent "$APP" "OneManCursor.zip")
    echo "Distribution build done (signature replaced with ad-hoc): dist/OneManCursor.zip / $BUILD_TAG"
fi
