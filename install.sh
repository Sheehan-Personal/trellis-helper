#!/bin/zsh
# Build trellis-helper into ~/.local/bin and (re)load its two launch agents.
# A rebuild changes the binary's signature, so macOS asks for Accessibility again afterwards.
set -euo pipefail
cd "${0:a:h}"
BIN=~/.local/bin/trellis-helper
LOG=~/Library/Logs/trellis-helper.log
WATCH=~/Library/Application\ Support/TrellisWM
mkdir -p ~/.local/bin ~/Library/LaunchAgents
swiftc -O -o "$BIN" main.swift
for name in repair snapshot; do
  label=com.mikesheehan.trellis-helper.$name
  dest=~/Library/LaunchAgents/$label.plist
  sed -e "s|BIN|$BIN|" -e "s|LOG|$LOG|" -e "s|WATCH|$WATCH|" launchd/$label.plist > "$dest"
  launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
  [[ $name == snapshot ]] && launchctl bootstrap gui/$(id -u) "$dest"
done
echo "installed $BIN; repair runs at next login, snapshot runs whenever TrellisWM saves"
