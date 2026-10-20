# trellis-helper

Keeps TrellisWM saved views working when a window closes or the Mac restarts.

TrellisWM pins each view to window numbers and deletes a window from its layout file as soon
as it closes. This tool keeps its own snapshot of the layout, plus a stable name for every
window in it: the app, the Chrome profile (from the window title) or the tmux session (for
iTerm). Repair finds today's window for each name, writes the snapshot back with the new
numbers and relaunches TrellisWM.

    trellis-helper status     each view, and which windows are found (→ new number, ✗ not open)
    trellis-helper repair     reattach views; also restarts missing tmux sessions + iTerm windows
    trellis-helper snapshot   accept the current views as the ones to restore

- **How it runs:** iTerm is a login item, and `~/.zshrc` starts `trellis-helper login` from every plain
  iTerm shell. A lock lets only the first one run: it repairs (waiting up to 4 minutes for windows to
  open), then snapshots every 15 seconds. It runs from iTerm because iTerm already has Accessibility;
  as a launchd job it needs its own grant, and macOS wouldn't keep one for this ad-hoc-signed binary.
- **Snapshots** are only taken while no view has lost a window. If you remove a window from a view on
  purpose, run `trellis-helper snapshot` once.
- Snapshots: `~/Library/Application Support/trellis-helper/snapshots/` (last 20).
  Log: `~/Library/Logs/trellis-helper.log`. Install or rebuild: `./install.sh`.

## Plugging into an external display

TrellisWM keeps one layout file per display and desktop, named
`arrangement-<display id>|<desktop id>.json`. The helper snapshots and repairs every one of those
files, not only the display you're looking at, so the views you saved with the external display
attached are in the snapshots like any other.

- **Plugging in or unplugging** doesn't close any window, and a window keeps its number when it moves
  between screens, so there is nothing to repair. The views on each display's layout file stay as they were.
- **After a restart with the display attached,** `repair` matches each view's windows by name (app,
  Chrome profile, tmux session) and rewrites both displays' files, then relaunches TrellisWM.
- **A view you saved on the external display** is picked up by the next 15-second snapshot. Run
  `trellis-helper snapshot` to take it sooner.
- **The unplugged display's views don't block snapshots.** The health check ignores windows the snapshot
  couldn't name, so views on a display that isn't connected don't stop the laptop's views from being saved.
- **Positions and sizes are TrellisWM's.** The helper restores which windows belong to which view,
  not where they sit on the screen.
