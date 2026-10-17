// trellis-helper: keeps TrellisWM saved views alive when windows close or the Mac restarts.
//
// TrellisWM pins each view to window numbers and deletes a window from its layout file the
// moment it closes. This tool keeps its own snapshot of the layout plus a stable name for
// every window in it (app, Chrome profile, tmux session). Repair finds today's window for
// each name, writes the snapshot back with the new numbers, and relaunches TrellisWM.

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let fm = FileManager.default
let appSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let trellisDir = appSupport.appendingPathComponent("TrellisWM")
let snapshotsDir = appSupport.appendingPathComponent("trellis-helper/snapshots")
let trellisBundle = "app.trellisui.trelliswm"
let keepSnapshots = 20

struct Identity: Codable, Hashable {
    let bundle: String
    let key: String    // Chrome profile or tmux session; empty for single-window apps
    let title: String  // tie-break only
    var name: String { key.isEmpty ? bundle : "\(bundle) [\(key)]" }
}

typealias Layout = [String: Any]

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(s)")
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: live windows

let tmuxPath = "/opt/homebrew/bin/tmux"

func tmux(_ args: String...) -> String { run(tmuxPath, args) }

func running(_ bundle: String) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }
}

/// iTerm window number -> tmux session shown in it (current tab first, then any tab).
func itermSessions() -> [CGWindowID: String] {
    guard !running("com.googlecode.iterm2").isEmpty else { return [:] }
    let script = """
    set sep to character id 9
    tell application "iTerm2"
      set out to ""
      repeat with w in windows
        set line_ to (id of w as text) & sep & (tty of current session of current tab of w)
        repeat with t in tabs of w
          repeat with s in sessions of t
            set line_ to line_ & sep & (tty of s)
          end repeat
        end repeat
        set out to out & line_ & linefeed
      end repeat
      return out
    end tell
    """
    var clients: [String: String] = [:]
    for line in tmux("list-clients", "-F", "#{client_tty} #{session_name}").split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 { clients[parts[0]] = parts[1] }
    }
    var result: [CGWindowID: String] = [:]
    for line in run("/usr/bin/osascript", ["-e", script]).split(separator: "\n") {
        let fields = line.split(separator: "\t").map(String.init)
        guard let id = fields.first.flatMap({ CGWindowID($0) }) else { continue }
        if let session = fields.dropFirst().lazy.compactMap({ clients[$0] }).first { result[id] = session }
    }
    return result
}

func liveWindows() -> [CGWindowID: Identity] {
    let tmux = itermSessions()
    var result: [CGWindowID: Identity] = [:]
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        guard let bundle = app.bundleIdentifier else { continue }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { continue }
        for window in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { continue }
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &t)
            let title = (t as? String) ?? ""
            var key = ""
            if bundle == "com.google.Chrome", let r = title.range(of: " - Google Chrome - ", options: .backwards) {
                key = String(title[r.upperBound...])
            } else if bundle == "com.googlecode.iterm2" {
                key = tmux[id] ?? ""
            }
            result[id] = Identity(bundle: bundle, key: key, title: title)
        }
    }
    return result
}

// MARK: layout files

func arrangementFiles(in dir: URL) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix("arrangement-") && $0.hasSuffix(".json") }.sorted()
}

func loadLayout(_ url: URL) -> Layout? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? Layout }
}

/// Every panel in the layout tree, by id, with its tab members.
func panels(_ node: Any, into out: inout [String: [String]]) {
    if let d = node as? [String: Any] {
        if let id = d["id"] as? String, let views = d["views"] as? [String] { out[id] = views }
        d.values.forEach { panels($0, into: &out) }
    } else if let a = node as? [Any] {
        a.forEach { panels($0, into: &out) }
    }
}

/// View number -> window ids in it (each panel expanded to its tabs).
func viewWindows(_ layout: Layout) -> [String: [String]] {
    var byId: [String: [String]] = [:]
    panels(layout["doc"] ?? [:], into: &byId)
    let framings = layout["framings"] as? [String: [String]] ?? [:]
    return framings.mapValues { $0.flatMap { byId[$0] ?? [$0] } }
}

// MARK: snapshots

struct Snapshot {
    let dir: URL
    let identities: [String: [String: Identity]]  // file -> window id ("w123") -> identity

    static func latest() -> Snapshot? {
        guard let name = ((try? fm.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []).sorted().last else { return nil }
        let dir = snapshotsDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("identities.json")),
              let ids = try? JSONDecoder().decode([String: [String: Identity]].self, from: data) else { return nil }
        return Snapshot(dir: dir, identities: ids)
    }

    func layout(_ file: String) -> Layout? { loadLayout(dir.appendingPathComponent(file)) }

    /// tmux session -> folder it was started in, for sessions an iTerm window in a view showed.
    var tmuxSessions: [String: String] {
        (try? Data(contentsOf: dir.appendingPathComponent("tmux-sessions.json")))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}

/// Healthy = no view in the latest snapshot has lost a window. Guards against snapshotting the
/// state TrellisWM leaves behind after a window closes or after a restart.
func unhealthyReason(_ latest: Snapshot) -> String? {
    for file in latest.identities.keys.sorted() {
        guard let old = latest.layout(file), let now = loadLayout(trellisDir.appendingPathComponent(file)) else { continue }
        let nowViews = viewWindows(now)
        for (view, windows) in viewWindows(old) where (nowViews[view]?.count ?? 0) < windows.count {
            return "view \(view) has \(nowViews[view]?.count ?? 0) of \(windows.count) windows"
        }
    }
    return nil
}

func snapshot(ifHealthy: Bool) {
    let files = arrangementFiles(in: trellisDir)
    if ifHealthy, let latest = Snapshot.latest() {
        if let reason = unhealthyReason(latest) { return log("snapshot skipped: \(reason) (run `trellis-helper snapshot` to accept it)") }
        let unchanged = files.allSatisfy {
            fm.contentsEqual(atPath: trellisDir.appendingPathComponent($0).path, andPath: latest.dir.appendingPathComponent($0).path)
        }
        if unchanged { return }
    }
    let live = liveWindows()
    var identities: [String: [String: Identity]] = [:]
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
    let dir = snapshotsDir.appendingPathComponent(f.string(from: Date()))
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for file in files {
        try! fm.copyItem(at: trellisDir.appendingPathComponent(file), to: dir.appendingPathComponent(file))
        let owners = loadLayout(trellisDir.appendingPathComponent(file))?["owners"] as? [String: String] ?? [:]
        identities[file] = owners.keys.reduce(into: [:]) { out, wid in
            // A stale file can hold a number macOS has since reused for another app's window.
            if let id = CGWindowID(wid.dropFirst()), let identity = live[id], identity.bundle == owners[wid] { out[wid] = identity }
        }
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! enc.encode(identities).write(to: dir.appendingPathComponent("identities.json"))
    let viewSessions = Set(identities.values.flatMap(\.values).filter { $0.bundle == "com.googlecode.iterm2" }.map(\.key))
    var folders: [String: String] = [:]
    // Space, not tab: under launchd there's no locale and tmux prints a tab as "_".
    for line in tmux("list-sessions", "-F", "#{session_name} #{session_path}").split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 1).map(String.init)
        if f.count == 2, viewSessions.contains(f[0]) { folders[f[0]] = f[1] }
    }
    try! enc.encode(folders).write(to: dir.appendingPathComponent("tmux-sessions.json"))
    let all = ((try? fm.contentsOfDirectory(atPath: snapshotsDir.path)) ?? []).sorted()
    all.dropLast(keepSnapshots).forEach { try? fm.removeItem(at: snapshotsDir.appendingPathComponent($0)) }
    log("snapshot \(dir.lastPathComponent): \(identities.values.map(\.count).reduce(0, +)) windows")
}

// MARK: repair

/// Recreate each view's tmux session if it's gone (restart) and give it an iTerm window if none shows it.
func ensureTerminals(_ latest: Snapshot) {
    let shown = Set(itermSessions().values)
    for (session, folder) in latest.tmuxSessions.sorted(by: { $0.key < $1.key }) {
        if !tmux("ls", "-F", "#{session_name}").split(separator: "\n").contains(Substring(session)) {
            _ = tmux("new-session", "-d", "-s", session, "-c", folder)
            log("tmux: started session \(session) in \(folder)")
        }
        if !shown.contains(session) {
            _ = run("/usr/bin/osascript", ["-e", "tell application \"iTerm2\" to create window with default profile command \"\(tmuxPath) attach -t \(session)\""])
            log("iTerm: opened a window on \(session)")
        }
    }
}

/// Old window id -> live window id, for one file. Nil entries had no live match.
func match(_ saved: [String: Identity], _ live: [CGWindowID: Identity]) -> [String: String?] {
    var used = Set<CGWindowID>()
    var result: [String: String?] = [:]
    // Exact titles first so a same-key tie goes to the window that hasn't changed.
    for (wid, identity) in saved.sorted(by: { $0.key < $1.key }) {
        let candidates = live.filter { $0.value.bundle == identity.bundle && $0.value.key == identity.key && !used.contains($0.key) }
        let pick = candidates.first { $0.key == CGWindowID(wid.dropFirst()) }?.key
            ?? candidates.first { $0.value.title == identity.title }?.key
            ?? (candidates.count == 1 ? candidates.first!.key : nil)
        if let pick { used.insert(pick) }
        result[wid] = pick.map { "w\($0)" }
    }
    return result
}

func rewrite(_ text: String, _ map: [String: String]) -> String {
    let regex = try! NSRegularExpression(pattern: "\"(w\\d+)\"")
    var out = text
    for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        let r = Range(m.range(at: 1), in: text)!
        if let new = map[String(text[r])] { out.replaceSubrange(r, with: new) }
    }
    return out
}

func quitTrellis() {
    running(trellisBundle).forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(15)
    while !running(trellisBundle).isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
}

func repair(wait: TimeInterval, dryRun: Bool) {
    guard let latest = Snapshot.latest() else { return log("repair: no snapshot yet; run `trellis-helper snapshot`") }
    if !dryRun { ensureTerminals(latest) }
    let deadline = Date().addingTimeInterval(wait)
    var plans: [String: [String: String?]] = [:]
    while true {
        let live = liveWindows()
        plans = latest.identities.mapValues { match($0, live) }
        let missing = plans.values.flatMap(\.values).filter { $0 == nil }.count
        if missing == 0 || Date() >= deadline { break }
        Thread.sleep(forTimeInterval: 5)
    }
    var writes: [String: String] = [:]
    var ghost = 900_000_000
    for (file, plan) in plans.sorted(by: { $0.key < $1.key }) {
        // Only a window that came back under a new number triggers repair; one still closed doesn't.
        guard plan.contains(where: { old, new in new != nil && new != old }) else { continue }
        guard let text = try? String(contentsOf: latest.dir.appendingPathComponent(file), encoding: .utf8) else { continue }
        var map: [String: String] = [:]
        for (old, new) in plan.sorted(by: { $0.key < $1.key }) {
            if let new { map[old] = new } else { ghost += 1; map[old] = "w\(ghost)" }  // keep it from colliding with a reused number
            if new != old { log("\(latest.identities[file]?[old]?.name ?? "?"): \(old) -> \(new ?? "not open")") }
        }
        writes[file] = rewrite(text, map)
    }
    if writes.isEmpty { return log("repair: views are current") }
    if dryRun { return log("repair: dry run, \(writes.count) file(s) would change") }
    quitTrellis()
    for (file, text) in writes { try! text.write(to: trellisDir.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    NSWorkspace.shared.openApplication(at: NSWorkspace.shared.urlForApplication(withBundleIdentifier: trellisBundle)!,
                                       configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    Thread.sleep(forTimeInterval: 5)
    log("repair: rewrote \(writes.count) file(s), relaunched TrellisWM")
    snapshot(ifHealthy: true)
}

// MARK: status

func status() {
    guard let latest = Snapshot.latest() else { return print("no snapshot yet") }
    print("snapshot \(latest.dir.lastPathComponent)")
    let live = liveWindows()
    for (file, saved) in latest.identities.sorted(by: { $0.key < $1.key }) {
        guard let layout = latest.layout(file) else { continue }
        let views = viewWindows(layout)
        guard !views.isEmpty else { continue }
        let plan = match(saved, live)
        print("\(file)")
        for (view, windows) in views.sorted(by: { $0.key < $1.key }) {
            let parts = windows.map { wid -> String in
                let name = saved[wid]?.name ?? "\(wid) (unnamed)"
                switch plan[wid] {
                case .some(.some(let new)) where new == wid: return name
                case .some(.some(let new)): return "\(name) → \(new)"
                default: return "\(name) ✗"
                }
            }
            print("  view \(view): \(parts.joined(separator: ", "))")
        }
    }
}

// MARK: main

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered, so the log shows each line as it happens
let args = Array(CommandLine.arguments.dropFirst())
// Runs from iTerm's shell, so it uses iTerm's Accessibility grant (a launchd job needs its own,
// and macOS wouldn't keep one for this ad-hoc-signed binary).
if !AXIsProcessTrusted() {
    log("no Accessibility permission: run from iTerm (System Settings → Privacy & Security → Accessibility)")
    exit(1)
}
switch args.first {
case "snapshot": snapshot(ifHealthy: args.contains("--if-healthy"))
case "repair":
    let wait = args.firstIndex(of: "--wait").flatMap { args.indices.contains($0 + 1) ? TimeInterval(args[$0 + 1]) : nil } ?? 0
    repair(wait: wait, dryRun: args.contains("--dry-run"))
case "status": status()
case "login":
    // Once per login, from the first iTerm shell: reattach views, then snapshot as TrellisWM saves.
    // Every new iTerm shell starts this; the lock makes every copy after the first exit at once.
    try? fm.createDirectory(at: snapshotsDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lock = open(snapshotsDir.deletingLastPathComponent().appendingPathComponent("login.lock").path, O_CREAT | O_RDWR, 0o644)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    repair(wait: 240, dryRun: false)
    while true { snapshot(ifHealthy: true); Thread.sleep(forTimeInterval: 15) }
default:
    print("""
    usage: trellis-helper snapshot [--if-healthy]   save views + window names
           trellis-helper repair [--wait SECS] [--dry-run]   reattach views to today's windows
           trellis-helper status                    show each view and whether its windows are found
           trellis-helper login                     repair, then keep snapshotting (started from ~/.zshrc)
    """)
}
