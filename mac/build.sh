#!/bin/bash
# Loading Dose Mac 앱을 빌드한다. 결과물: mac/build/Loading Dose.app
# (실행 파일 이름과 번들 ID는 예전 이름 Enter 를 그대로 쓴다. 바꾸면 권한과 저장된 기록이 끊긴다.)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Loading Dose.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ../packs/kmle.txt "$APP/Contents/Resources/kmle.txt"
# Apple Silicon 과 인텔 Mac 양쪽에서 돌도록 두 번 빌드해 하나로 합친다.
TMP="$(mktemp -d)"
swiftc -O -target arm64-apple-macos12.0 -o "$TMP/arm64" main.swift
swiftc -O -target x86_64-apple-macos12.0 -o "$TMP/x86_64" main.swift
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/Enter"
rm -rf "$TMP"
codesign --force --sign - "$APP"
echo "빌드 완료: $(pwd)/$APP"
