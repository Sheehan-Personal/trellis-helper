#!/bin/zsh
# Build TrellisHelper.app (a bundle, so Accessibility has one named entry for it) and
# (re)load its two launch agents. The binary is replaced only when it changed, because
# a new binary needs Accessibility granted again.
set -euo pipefail
cd "${0:a:h}"
APP=~/Applications/TrellisHelper.app
BIN=$APP/Contents/MacOS/trellis-helper
LOG=~/Library/Logs/trellis-helper.log
WATCH=~/Library/Application\ Support/TrellisWM
mkdir -p "$APP/Contents/MacOS" ~/.local/bin ~/Library/LaunchAgents
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o build.tmp main.swift
if [[ -f "$BIN" ]] && cmp -s build.tmp "$BIN"; then
  rm build.tmp; echo "binary unchanged; Accessibility grant kept"
else
  mv build.tmp "$BIN"
  codesign --force --sign - --identifier com.mikesheehan.trellis-helper "$APP"
  echo "new binary: grant Accessibility to $APP"
fi
ln -sf "$BIN" ~/.local/bin/trellis-helper
for name in repair snapshot; do
  label=com.mikesheehan.trellis-helper.$name
  dest=~/Library/LaunchAgents/$label.plist
  sed -e "s|BIN|$BIN|" -e "s|LOG|$LOG|" -e "s|WATCH|$WATCH|" launchd/$label.plist > "$dest"
  launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
  [[ $name == snapshot ]] && launchctl bootstrap gui/$(id -u) "$dest"
done
echo "installed; repair runs at next login, snapshot runs whenever TrellisWM saves"
