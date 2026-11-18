#!/usr/bin/env bash
#
# Builds TaskBar.app from the Swift package, with no Xcode project involved:
#
#   test  ->  release build  ->  assemble the .app bundle  ->  code sign
#
# Usage: scripts/build.sh [--skip-tests] [--universal] [--open]
#
# Environment:
#   VERSION            Marketing version stamped into Info.plist (default: contents of VERSION)
#   BUNDLE_ID          Bundle identifier (default: io.github.thomazzi98.taskbar)
#   CODESIGN_IDENTITY  Signing identity (default: "-", an ad-hoc signature)
#
# Note on ad-hoc signing: macOS ties privacy permissions (microphone, calendar) to the code
# signature, so it asks for them again after each rebuild. Set CODESIGN_IDENTITY to a
# "Developer ID Application" or "Apple Development" identity to keep them across builds.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="TaskBar"
BUNDLE_ID="${BUNDLE_ID:-io.github.thomazzi98.taskbar}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

RUN_TESTS=1
UNIVERSAL=0
OPEN_AFTER=0

for argument in "$@"; do
  case "$argument" in
    --skip-tests) RUN_TESTS=0 ;;
    --universal) UNIVERSAL=1 ;;
    --open) OPEN_AFTER=1 ;;
    -h | --help)
      sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown option '$argument' (try --help)" >&2
      exit 64
      ;;
  esac
done

step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

build_flags=(--configuration release --product "$APP_NAME")
if [[ $UNIVERSAL -eq 1 ]]; then
  build_flags+=(--arch arm64 --arch x86_64)
fi

if [[ $RUN_TESTS -eq 1 ]]; then
  step "Running tests"
  swift test
fi

step "Building $APP_NAME $VERSION ($BUILD_NUMBER)"
swift build "${build_flags[@]}"
BINARY="$(swift build "${build_flags[@]}" --show-bin-path)/$APP_NAME"

step "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

step "Signing"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  # A real identity gets the hardened runtime, which is what notarization requires.
  codesign --force --options runtime --timestamp \
    --entitlements Resources/TaskBar.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

SIZE="$(du -sh "$APP" | cut -f1 | tr -d '[:space:]')"
step "Built $APP ($SIZE)"

if [[ $OPEN_AFTER -eq 1 ]]; then
  open "$APP"
fi
