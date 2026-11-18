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
mkdir -p "$APP/Contents/Resources/pet"
cp ../omogi/pet/sprites.png "$APP/Contents/Resources/pet/sprites.png"
# Apple Silicon 과 인텔 Mac 양쪽에서 돌도록 두 번 빌드해 하나로 합친다.
TMP="$(mktemp -d)"
swiftc -O -target arm64-apple-macos12.0 -o "$TMP/arm64" main.swift quiz.swift ../omogi/pet.swift
swiftc -O -target x86_64-apple-macos12.0 -o "$TMP/x86_64" main.swift quiz.swift ../omogi/pet.swift
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/Enter"
rm -rf "$TMP"
# 서명: 키체인에 "Loading Dose Dev" 코드 서명 인증서가 있으면 그걸로 서명한다.
# 그러면 다시 빌드해도 손쉬운 사용 권한이 유지된다. 없으면 임시 서명(ad-hoc)이라 빌드할 때마다 권한을 새로 줘야 한다.
SIGN_ID="${LOADING_DOSE_SIGN_ID:-Loading Dose Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "서명: $SIGN_ID"
else
  codesign --force --sign - "$APP"
  echo "서명: 임시 서명 (인증서 \"$SIGN_ID\" 없음)"
fi
echo "빌드 완료: $(pwd)/$APP"
