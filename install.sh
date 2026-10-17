#!/bin/zsh
# Build trellis-helper into ~/.local/bin. It runs from iTerm (see the ~/.zshrc block in README),
# which already has Accessibility, so there is nothing to grant.
set -euo pipefail
cd "${0:a:h}"
swiftc -O -o ~/.local/bin/trellis-helper.tmp main.swift
mv ~/.local/bin/trellis-helper.tmp ~/.local/bin/trellis-helper
echo "installed ~/.local/bin/trellis-helper"
