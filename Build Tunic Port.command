#!/bin/bash
# Double-click me (right-click > Open the first time). Builds tunic-ios-port from your own GOG copy of Tunic for Mac.
cd "$(dirname "$0")"
if [ -z "${GAME_APP:-}" ]; then
  echo "Drag your Tunic.app (from the GOG 'Tunic' folder) into this window and press Return:"
  read -r GAME_APP; GAME_APP="${GAME_APP%/}"; GAME_APP="${GAME_APP//\\ / }"; GAME_APP="${GAME_APP%\'}"; GAME_APP="${GAME_APP#\'}"
fi
export GAME_APP
if ! xcode-select -p >/dev/null 2>&1; then echo "Xcode is required (install it from the App Store)"; read -r -p "Press Return to close"; exit 1; fi
mkdir -p build; ./build.sh 2>&1 | tee build/build.log
echo; echo "Log: $(pwd)/build/build.log"; open build 2>/dev/null
read -r -p "Press Return to close"
