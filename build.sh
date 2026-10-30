#!/bin/sh
# OneManCursor.app（ワンマンカーソル）を組み立てる
# 使い方: sh build.sh
set -e
cd "$(dirname "$0")"

APP="OneManCursor.app"
# ソースのビルド番号を表示する(どの版を作っているか一目で分かるように)
BUILD_TAG=$(grep -o '"Build [0-9-]*"' main.swift | head -1 | tr -d '"')
echo "ビルド番号: $BUILD_TAG"
# アイコンに焼き込むための末尾の番号(例: 32)
BUILD_NUM=$(printf '%s' "$BUILD_TAG" | awk -F- '{print $NF}')
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# アイコン生成（make_icon.swift → iconset → icns）
swiftc make_icon.swift -o /tmp/onemancursor_make_icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
/tmp/onemancursor_make_icon "$ICONSET" "$BUILD_NUM"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 本体（Apple Silicon / Intel 両対応のユニバーサルバイナリ）
# main.swift = スワイプ/共有(FinderSwipe 由来)、cursor.swift = カーソル表示(AlwaysCursor 由来)
swiftc -O -framework Cocoa -framework ApplicationServices -framework IOKit -framework ServiceManagement -framework UniformTypeIdentifiers \
    -target arm64-apple-macos13.0 main.swift cursor.swift -o /tmp/OneManCursor-arm64
swiftc -O -framework Cocoa -framework ApplicationServices -framework IOKit -framework ServiceManagement -framework UniformTypeIdentifiers \
    -target x86_64-apple-macos13.0 main.swift cursor.swift -o /tmp/OneManCursor-x86_64
lipo -create /tmp/OneManCursor-arm64 /tmp/OneManCursor-x86_64 -output "$APP/Contents/MacOS/OneManCursor"
cp Info.plist "$APP/Contents/Info.plist"
# 署名: Apple Development の証明書があればそれを使う(作り直しても同一アプリとして扱われ、
# 許可まわりや Gatekeeper の判定が安定する)。無い場合だけ場当たり署名にする
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -n "$SIGN_ID" ]; then
    echo "署名: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" "$APP"
else
    echo "署名: 場当たり（Apple Development 証明書が見つかりませんでした）"
    codesign --force --deep --sign - "$APP"
fi
echo "できた: $APP / $BUILD_TAG"

# 配布用: sh build.sh dist
# 自分用の署名(証明書名に Apple ID のメアドが入る)をはがして場当たり署名に付け替え、
# 配布用 zip を作る。自分用の $APP はそのまま残る
if [ "$1" = "dist" ]; then
    rm -rf dist
    mkdir -p dist
    cp -R "$APP" "dist/$APP"
    # 配布用はアイコンを標準(ビルド番号なし)に戻す。通常ビルドの番号入りアイコンは
    # 開発中の版の見分け用なので、安定版として配る方には入れない
    DIST_ICONSET="$(mktemp -d)/AppIcon.iconset"
    /tmp/onemancursor_make_icon "$DIST_ICONSET"
    iconutil -c icns "$DIST_ICONSET" -o "dist/$APP/Contents/Resources/AppIcon.icns"
    codesign --force --deep --sign - "dist/$APP"
    if codesign -dv "dist/$APP" 2>&1 | grep -q "Apple Development"; then
        echo "エラー: 配布用アプリに Apple Development 署名が残っています"
        exit 1
    fi
    (cd dist && ditto -c -k --keepParent "$APP" "OneManCursor.zip")
    echo "配布用できた（署名は場当たり署名に付け替え済み）: dist/OneManCursor.zip / $BUILD_TAG"
fi
