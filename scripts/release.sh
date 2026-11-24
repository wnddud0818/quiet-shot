#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
TAG=${1:?Usage: bash scripts/release.sh <new-release-tag>}
test "$(git branch --show-current)" = main || { echo 'Run from main.' >&2; exit 1; }
test -z "$(git status --porcelain)" || { echo 'Commit all changes first.' >&2; exit 1; }
git fetch origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" || { echo 'Sync main with origin first.' >&2; exit 1; }
gh auth status
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release already exists: $TAG" >&2
  exit 1
fi
xcodebuild -project QuietShot.xcodeproj -scheme QuietShot \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/QuietShot.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' archive
APP=build/QuietShot.xcarchive/Products/Applications/QuietShot.app
test -d "$APP"
PACKAGE=$(mktemp -d "${TMPDIR:-/tmp}/quietshot-release.XXXXXX")
trap 'rm -rf "$PACKAGE"' EXIT
mkdir "$PACKAGE/Payload"
cp -R "$APP" "$PACKAGE/Payload/"
(cd "$PACKAGE" && zip -qry QuietShot-unsigned.ipa Payload)
cp "$PACKAGE/QuietShot-unsigned.ipa" build/QuietShot-unsigned.ipa
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist")
gh release create "$TAG" build/QuietShot-unsigned.ipa \
  --target "$(git rev-parse HEAD)" --latest \
  --title "QuietShot $VERSION ($TAG)" \
  --notes "Mac에서 직접 빌드한 서명 없는 IPA입니다. Sideloadly 또는 AltStore로 본인 Apple ID 서명 후 설치하세요. 커밋 $(git rev-parse HEAD)"
