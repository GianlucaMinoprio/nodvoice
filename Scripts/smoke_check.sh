#!/usr/bin/env bash
# Lightweight structural checks when full Xcode.app is not selected.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== file tree =="
find NodVoice -type f | sort

echo
echo "== swift presence =="
count=$(find NodVoice -name '*.swift' | wc -l | tr -d ' ')
test "$count" -ge 8
echo "swift files: $count"

echo
echo "== required symbols =="
rg -n "CMHeadphoneMotionManager|api.x.ai/v1/stt|api.x.ai/v1/tts|chat/completions|gestureSubject" NodVoice

echo
echo "== xcodeproj =="
test -f NodVoice.xcodeproj/project.pbxproj
echo "ok: NodVoice.xcodeproj"

if command -v xcodebuild >/dev/null 2>&1; then
  if xcodebuild -version >/dev/null 2>&1; then
    echo
    echo "== xcodebuild list =="
    xcodebuild -project NodVoice.xcodeproj -list
  else
    echo "xcodebuild present but Xcode.app not selected (CLI tools only) — skip compile"
  fi
fi

echo
echo "All structural checks passed."
