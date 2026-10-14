#!/bin/bash
# Builds LM Monitor into dist/LMMonitor.app and LMMonitor.dmg.
# Double-click this file (it opens in Terminal), or run: ./build.command
cd "$(dirname "$0")" || exit 1
LAUNCH=1
for a in "$@"; do [ "$a" = "--no-launch" ] && LAUNCH=0; done
LOG="build.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "== LM Monitor build  $(date)"
echo "== macOS $(sw_vers -productVersion 2>/dev/null)  arch $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "!! Xcode Command Line Tools are not installed."
  echo "   A system dialog will open — click Install, wait for it to finish, then run this file again."
  xcode-select --install
  echo "STATUS=NEED_CLT"
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "!! swift not found on PATH even though CLT are installed."; echo "STATUS=NO_SWIFT"; exit 1
fi
swift --version 2>&1 | head -2

echo "== Building (release)…"
if ! swift build -c release 2>&1; then
  echo "STATUS=BUILD_FAILED"
  exit 1
fi
BIN=".build/release/LMMonitor"
[ -x "$BIN" ] || { echo "!! binary missing"; echo "STATUS=BUILD_FAILED"; exit 1; }

echo "== Self-test (log parsers, state machine, alerts)…"
if ! "$BIN" --selftest; then
  echo "STATUS=SELFTEST_FAILED"
  exit 1
fi

echo "== Packaging app bundle…"
APP="dist/LMMonitor.app"
rm -rf dist LMMonitor.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LMMonitor"
cp packaging/Info.plist "$APP/Contents/Info.plist"
if [ -d packaging/AppIcon.iconset ]; then
  iconutil -c icns packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>&1 || echo "   (icon conversion failed, continuing without icon)"
fi
codesign --force --deep --sign - "$APP" 2>&1 || echo "   (ad-hoc codesign failed, continuing)"

echo "== Creating DMG…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "LM Monitor" -srcfolder "$STAGE" -ov -format UDZO "LMMonitor.dmg" >/dev/null 2>&1 \
  && echo "   LMMonitor.dmg ready ($(du -h LMMonitor.dmg | cut -f1))" || echo "   (DMG creation failed)"
rm -rf "$STAGE"

if [ "$LAUNCH" = 1 ]; then
  echo "== Launching app…"
  pkill -x LMMonitor 2>/dev/null
  # The old copy needs up to ~1 s to stop its lms helpers; `open` would just hand off to it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x LMMonitor >/dev/null || break; sleep 0.3; done
  open "$APP"
fi
echo "STATUS=OK"
echo
echo "Done. Open LMMonitor.dmg and drag LM Monitor to Applications."
echo "It reads LM Studio's own logs, so no proxy or tool changes are needed."
echo "You can close this window."
