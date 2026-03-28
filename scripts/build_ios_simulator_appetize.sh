#!/usr/bin/env bash
# بناء Runner.app للمحاكي (iOS Simulator) — بدون IPA وبدون ExportOptions
# للاستخدام على macOS أو Codemagic (يتطلب Xcode + CocoaPods).
#
# المخرجات:
#   - نسخة من Runner.app تحت: build/ios/iphonesimulator/Runner.app
#   - أرشيف zip: build/ios/iphonesimulator/Runner_simulator_appetize.zip
#
# ملاحظة: Flutter يضع البناء عادة تحت Debug-iphonesimulator أو Release-iphonesimulator؛
#         يتم النسخ إلى build/ios/iphonesimulator/ للتوافق مع Appetize والمسار المطلوب.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Project root: $ROOT"

echo "==> flutter pub get"
flutter pub get

echo "==> pod install"
( cd ios && pod install --repo-update )

# بناء للمحاكي فقط — لا IPA. --no-codesign يقلل الاعتماد على التوقيع (جهاز التطوير/المحاكي).
# إن فشل --no-codesign مع إصدار Flutter، أعد المحاولة بدونها يدوياً.
set +e
flutter build ios --simulator --debug --no-codesign
BUILD_OK=$?
set -e
if [ "$BUILD_OK" -ne 0 ]; then
  echo "WARN: build with --no-codesign failed; retrying without --no-codesign"
  flutter build ios --simulator --debug
fi

RUNNER_SRC=""
for cand in \
  "build/ios/Debug-iphonesimulator/Runner.app" \
  "build/ios/Release-iphonesimulator/Runner.app" \
  "build/ios/iphonesimulator/Runner.app"; do
  if [ -d "$cand" ]; then
    RUNNER_SRC="$cand"
    break
  fi
done

if [ -z "$RUNNER_SRC" ]; then
  RUNNER_SRC="$(find build/ios -type d -name "Runner.app" 2>/dev/null | grep -E 'iphonesimulator' | head -n 1 || true)"
fi

if [ -z "$RUNNER_SRC" ] || [ ! -d "$RUNNER_SRC" ]; then
  echo "ERROR: Runner.app not found under build/ios"
  find build/ios -maxdepth 6 -type d 2>/dev/null || true
  exit 1
fi

echo "==> Found Runner.app at: $RUNNER_SRC"

OUT_DIR="build/ios/iphonesimulator"
rm -rf "$OUT_DIR/Runner.app"
mkdir -p "$OUT_DIR"
cp -R "$RUNNER_SRC" "$OUT_DIR/Runner.app"

echo "==> Verifying: $OUT_DIR/Runner.app"
test -d "$OUT_DIR/Runner.app"

ZIP_NAME="${ZIP_NAME:-Runner_simulator_appetize.zip}"
( cd "$OUT_DIR" && rm -f "$ZIP_NAME" && zip -qry "$ZIP_NAME" Runner.app )

ZIP_PATH="$ROOT/$OUT_DIR/$ZIP_NAME"
echo "==> ZIP created: $ZIP_PATH"
ls -la "$OUT_DIR"
