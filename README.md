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
  open), then snapshots every 15 seconds. Before each snapshot it also reattaches views if an app
  restarted mid-session (an update, say) and its windows came back under new numbers. It runs from iTerm because iTerm already has Accessibility;
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

- **Views follow you between displays.** TrellisWM keeps separate views per display, so views saved
  undocked would never reach the dock's display. The helper notes when each display's views are edited,
  and when you dock or undock and only one display is left on, it gives that display the views edited
  most recently on the other, then relaunches TrellisWM once. With the lid open and docked (two displays
  on) it copies nothing, so each screen keeps its own views. State: `~/Library/Application Support/trellis-helper/views-seen.json`.
- **After a restart with the display attached,** `repair` matches each view's windows by name (app,
  Chrome profile, tmux session) and rewrites both displays' files, then relaunches TrellisWM.
- **A view you saved on the external display** is picked up by the next 15-second snapshot. Run
  `trellis-helper snapshot` to take it sooner.
- **The unplugged display's views don't block snapshots.** The health check ignores windows the snapshot
  couldn't name, so views on a display that isn't connected don't stop the laptop's views from being saved.
- **Positions and sizes are TrellisWM's.** The helper restores which windows belong to which view,
  not where they sit on the screen.
