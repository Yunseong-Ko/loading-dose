#!/bin/bash
# 이 Mac 에서 Loading Dose 를 서명할 인증서("Loading Dose Dev")를 만들어 로그인 키체인에 넣는다.
# 한 번만 실행하면 된다. 그 뒤로는 mac/build.sh 가 이 인증서로 서명하므로,
# 앱을 다시 빌드해도 손쉬운 사용 권한이 유지된다.
# (자체 서명이라 이 Mac 에서만 의미가 있다. 다른 사람에게 배포할 때의 "열 수 없음" 경고는 그대로다.)
set -euo pipefail

NAME="Loading Dose Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "이미 있습니다: $NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# macOS 에 들어 있는 /usr/bin/openssl 을 쓴다 (다른 openssl 이 만든 파일은 키체인이 못 읽는 경우가 있다).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# 아래 암호는 방금 만든 임시 파일을 키체인으로 옮기는 데만 쓰이고, 파일은 끝나면 지워진다.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:loading-dose-temp

security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P loading-dose-temp -T /usr/bin/codesign

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "만들었습니다: $NAME"
else
  echo "인증서를 넣었지만 목록에서 찾지 못했습니다. 키체인 접근 앱의 '나의 인증서'를 확인해 주세요." >&2
  exit 1
fi
