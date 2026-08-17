#!/bin/bash
#
# 배포용 zip 만들기 — 유니버설 Release 빌드 → 검증 → dist/winder-<버전>.zip
#
#   ./scripts/release.sh
#
# 서명은 ad-hoc이므로 받는 사람이 Gatekeeper를 만날 수 있다. USB로 건네면 격리 표시가
# 붙지 않아 바로 열린다. 자세한 내용은 README의 "공유용 zip 만들기" 참고.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="winder.xcodeproj"
SCHEME="winder"
DERIVED="build/ReleaseDD"
APP="$DERIVED/Build/Products/Release/winder.app"
OUT_DIR="dist"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

step "Release 빌드 (arm64 + x86_64)"
# ARCHS/ONLY_ACTIVE_ARCH를 명령줄에 넘겨야 한다 — 프로젝트 설정에 같은 값이 있어도
# xcodebuild가 무시하고 현재 기기 아키텍처(arm64)만 만든다
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    clean build 2>&1 | grep -E "error:|warning:|BUILD" | grep -v AppIntents | sort -u

[ -d "$APP" ] || fail "빌드 산출물이 없습니다: $APP"

step "아키텍처 확인"
BINARY="$APP/Contents/MacOS/winder"
ARCH_INFO=$(lipo -info "$BINARY")
echo "  $ARCH_INFO"
case "$ARCH_INFO" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *) fail "유니버설이 아닙니다 — 인텔 맥에서 실행되지 않습니다" ;;
esac

step "서명 확인"
codesign --verify --deep --strict "$APP" || fail "서명 검증 실패"
echo "  통과 ($(codesign -dvv "$APP" 2>&1 | grep -m1 Signature))"

step "압축"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$OUT_DIR/winder-$VERSION.zip"
mkdir -p "$OUT_DIR"
rm -f "$ZIP"
# 로컬 빌드에 붙었을 수 있는 확장 속성 제거 — 받는 쪽에서 격리 경고가 뜨지 않게
xattr -cr "$APP"
# zip -r 대신 ditto: --keepParent가 .app 묶음을 유지하고,
# 프레임워크가 생겼을 때 심볼릭 링크를 풀어 서명을 깨뜨리지 않는다
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

step "완료"
echo "  $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "  최소 macOS: $(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")"
echo
echo "  USB로 건네면 바로 열립니다."
echo "  메일·메신저로 보내면 받는 쪽에서 시스템 설정 › 개인정보 보호 및 보안 ›"
echo "  \"그래도 열기\"를 한 번 눌러야 합니다."
