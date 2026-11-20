#!/bin/bash
# Omogi Mac 앱을 빌드한다. 결과물: omogi/build/Omogi.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Omogi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pet"
cp Info.plist "$APP/Contents/Info.plist"
cp ../mac/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 아이콘은 Loading Dose 와 같은 오모기 얼굴
cp pet/sprites.png "$APP/Contents/Resources/pet/sprites.png"
cp pet/wear.png "$APP/Contents/Resources/pet/wear.png"       # 옷 (맨몸 그림 위에 겹친다)
cp ../packs/kmle.txt "$APP/Contents/Resources/kmle.txt"     # O/X 기본 문항 (Loading Dose 와 같은 팩)
# 편지 서버 주소와 공개용 키 (있을 때만). 없으면 편지는 연습 배달만 된다.
if [ -f server.json ]; then cp server.json "$APP/Contents/Resources/server.json"; fi
# Apple Silicon 과 인텔 Mac 양쪽에서 돌도록 두 번 빌드해 하나로 합친다.
TMP="$(mktemp -d)"
swiftc -O -target arm64-apple-macos12.0 -o "$TMP/arm64" main.swift pet.swift focus.swift calendar.swift letters.swift server.swift quizwatch.swift wardrobe.swift village.swift ../mac/quiz.swift
swiftc -O -target x86_64-apple-macos12.0 -o "$TMP/x86_64" main.swift pet.swift focus.swift calendar.swift letters.swift server.swift quizwatch.swift wardrobe.swift village.swift ../mac/quiz.swift
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/Omogi"
rm -rf "$TMP"
# 서명: 키체인에 코드 서명 인증서(tools/make_signing_cert.sh 가 만드는 "Loading Dose Dev")가 있으면 그걸로 서명한다.
# 그러면 다시 빌드해도 손쉬운 사용·캘린더 권한이 유지된다. 없으면 임시 서명(ad-hoc)이다.
SIGN_ID="${OMOGI_SIGN_ID:-Loading Dose Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "서명: $SIGN_ID"
else
  codesign --force --sign - "$APP"
  echo "서명: 임시 서명 (인증서 \"$SIGN_ID\" 없음)"
fi
echo "빌드 완료: $(pwd)/$APP"
