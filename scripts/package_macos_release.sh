#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$ROOT_DIR/.release-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-work}"
ARCHS="${ARCHS:-arm64}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.4}"
APP_NAME="Speak"
SCHEME="VoiceInk"
PROJECT="$ROOT_DIR/VoiceInk.xcodeproj"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 1
  fi
}

fail_local_signing() {
  cat >&2 <<'EOF'
Refusing to create public macOS release artifacts without Developer ID signing.

Required environment:
  DEVELOPER_ID_APPLICATION   Developer ID Application identity name
  APPLE_ID                   Apple ID used for notarytool
  APPLE_TEAM_ID              Apple Developer team ID
  APPLE_APP_SPECIFIC_PASSWORD App-specific password or notarytool password

Use `make local` for private/local ad-hoc builds. Do not upload local builds
as GitHub release DMGs or ZIPs.
EOF
  exit 1
}

for tool in xcodebuild codesign ditto hdiutil plutil spctl xcrun /usr/libexec/PlistBuddy; do
  require_tool "$tool"
done

[[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] || fail_local_signing
require_env APPLE_ID
require_env APPLE_TEAM_ID
require_env APPLE_APP_SPECIFIC_PASSWORD

rm -rf "$DERIVED_DATA" "$WORK_DIR"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  "CODE_SIGN_IDENTITY[sdk=macosx*]=$DEVELOPER_ID_APPLICATION" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  CODE_SIGN_ENTITLEMENTS="$ROOT_DIR/VoiceInk/VoiceInk.entitlements" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
ZIP_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"
NOTARY_ZIP="$WORK_DIR/$APP_NAME-$VERSION-notary.zip"
DMG_ROOT="$WORK_DIR/dmg-root"
ENTITLEMENTS_PLIST="$WORK_DIR/entitlements.plist"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH" 2>"$WORK_DIR/codesign-details.txt"

if grep -q "Signature=adhoc" "$WORK_DIR/codesign-details.txt"; then
  echo "Built app is ad-hoc signed; refusing to package." >&2
  exit 1
fi

if grep -q "TeamIdentifier=not set" "$WORK_DIR/codesign-details.txt"; then
  echo "Built app has no TeamIdentifier; refusing to package." >&2
  exit 1
fi

codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_PLIST" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
  echo "Built app has get-task-allow entitlement; refusing to package." >&2
  exit 1
fi

ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

rm -f "$ZIP_PATH" "$DMG_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

shasum -a 256 "$ZIP_PATH" "$DMG_PATH" >"$OUTPUT_DIR/checksums-$VERSION.txt"

cat <<EOF
Packaged $APP_NAME $VERSION ($BUILD)
ZIP: $ZIP_PATH
DMG: $DMG_PATH
Checksums: $OUTPUT_DIR/checksums-$VERSION.txt
Architectures: $ARCHS
Minimum macOS: $MACOSX_DEPLOYMENT_TARGET
EOF
