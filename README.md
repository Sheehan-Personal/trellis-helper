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

- **Snapshot** runs automatically whenever TrellisWM saves, but only while no view has lost a
  window. If you remove a window from a view on purpose, run `trellis-helper snapshot` once.
- **Repair** runs at login. It waits up to 4 minutes for windows to open, then relaunches TrellisWM.
- Snapshots: `~/Library/Application Support/trellis-helper/snapshots/` (last 20).
  Log: `~/Library/Logs/trellis-helper.log`.
- `./install.sh` builds `~/Applications/TrellisHelper.app`, links `~/.local/bin/trellis-helper` to it and
  loads the agents. Grant Accessibility to TrellisHelper.app; the grant is kept unless the binary changes.
