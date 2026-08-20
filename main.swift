import AppKit
import SwiftUI
import SQLite3

// MARK: - Data model

struct SessionActivity: Identifiable, Equatable {
    let id: String
    let title: String
    let project: String
    let agent: String
    let modelId: String
    let cost: Double
    let tokensIn: Int64
    let tokensOut: Int64
    let status: Status
    let action: String
    let toolStart: Int64?
    let age: Int64            // ms since latest part update

    enum Status: String { case running, thinking, responding, done
        var emoji: String {
            switch self {
            case .running: return "⚡"
            case .thinking: return "🤔"
            case .responding: return "💬"
            case .done: return "✅"
            }
        }
        var color: Color {
            switch self {
            case .running: return .green
            case .thinking: return .orange
            case .responding: return .cyan
            case .done: return .gray
            }
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.age == rhs.age && lhs.status == rhs.status }
}

// MARK: - Activity store

final class ActivityStore: ObservableObject {
    @Published var activities: [SessionActivity] = []
    @Published var updatedAt: Date = Date()
    @Published var dbExists: Bool = true

    private let dbURI: String
    private let activeWindowMs: Int64 = 20_000   // only show sessions active within last 20s

    init() {
        let p = ProcessInfo.processInfo.environment["OPENCODE_WIDGET_DB"]
            ?? "\(NSHomeDirectory())/.local/share/opencode/opencode.db"
        dbURI = "file:\(p)?mode=ro"
    }

    private var pending: DispatchWorkItem?
    private var walWatcher: FileWatcher?

    func start() {
        refresh()
        walWatcher = FileWatcher(path: dbPath + "-wal") { [weak self] in self?.scheduleRefresh() }
        // safety net in case FS events are missed (e.g. during WAL checkpoint)
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.scheduleRefresh() }
    }

    // debounce coalescing bursts of FS writes into one refresh
    func scheduleRefresh() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: self.dbPath) else {
                DispatchQueue.main.async { self.dbExists = false; self.activities = []; self.updatedAt = Date() }
                return
            }
            let result = self.query()
            DispatchQueue.main.async { self.dbExists = true; self.activities = result; self.updatedAt = Date() }
        }
    }

    private var dbPath: String { dbURI.replacingOccurrences(of: "file:", with: "").components(separatedBy: "?").first ?? "" }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(dbURI, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_exec(db, "PRAGMA query_only=ON;", nil, nil, nil)
        return db
    }

    private func query() -> [SessionActivity] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var out: [SessionActivity] = []

        var stmt: OpaquePointer?
        let sql = """
            SELECT id, title, directory, agent, model, cost, tokens_input, tokens_output
            FROM session WHERE time_archived IS NULL
            ORDER BY time_updated DESC LIMIT 15;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id    = col(sqlite3_column_text(stmt, 0))
            let title = col(sqlite3_column_text(stmt, 1))
            let dir   = col(sqlite3_column_text(stmt, 2))
            let agent = col(sqlite3_column_text(stmt, 3))
            let model = col(sqlite3_column_text(stmt, 4))
            let cost  = sqlite3_column_double(stmt, 5)
            let tin   = sqlite3_column_int64(stmt, 6)
            let tout  = sqlite3_column_int64(stmt, 7)

            let project = (dir as NSString).lastPathComponent
            let modelId = parseModelId(model) ?? model

            guard let latest = latestPart(db: db, session: id) else { continue }
            let age = now - latest.timeUpdated
            if age > activeWindowMs { continue }   // not active right now -> skip

            out.append(SessionActivity(
                id: id, title: title.isEmpty ? "未命名会话" : title,
                project: project.isEmpty ? "—" : project,
                agent: agent, modelId: modelId, cost: cost,
                tokensIn: tin, tokensOut: tout,
                status: latest.status, action: latest.action,
                toolStart: latest.toolStart, age: age
            ))
        }
        // most active first
        return out.sorted { $0.age < $1.age }
    }

    private struct LatestPart {
        let status: SessionActivity.Status
        let action: String
        let toolStart: Int64?
        let timeUpdated: Int64
    }

    private func latestPart(db: OpaquePointer?, session: String) -> LatestPart? {
        var stmt: OpaquePointer?
        let sql = "SELECT data, time_updated FROM part WHERE session_id=?1 ORDER BY time_updated DESC, rowid DESC LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        var found: LatestPart?
        session.withCString { cId in
            sqlite3_bind_text(stmt, 1, cId, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let dataStr = col(sqlite3_column_text(stmt, 0))
                let tu = sqlite3_column_int64(stmt, 1)
                if let data = dataStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    found = derive(obj: obj, timeUpdated: tu)
                }
            }
            sqlite3_finalize(stmt)
        }
        return found ?? LatestPart(status: .done, action: "空闲", toolStart: nil, timeUpdated: 0)
    }

    private func derive(obj: [String: Any], timeUpdated: Int64) -> LatestPart {
        let type = obj["type"] as? String ?? ""
        switch type {
        case "tool":
            let tool = obj["tool"] as? String ?? "tool"
            let state = obj["state"] as? [String: Any] ?? [:]
            let st = state["status"] as? String ?? ""
            let input = state["input"] as? [String: Any] ?? [:]
            let time = state["time"] as? [String: Any] ?? [:]
            let start = int64(time["start"])
            let desc = describeInput(tool: tool, input: input)
            if st == "running" {
                return LatestPart(status: .running, action: "\(tool) · \(desc)", toolStart: start, timeUpdated: timeUpdated)
            }
            return LatestPart(status: .done, action: "\(tool) ✓ \(desc)", toolStart: nil, timeUpdated: timeUpdated)
        case "reasoning":
            return LatestPart(status: .thinking, action: "思考中…", toolStart: nil, timeUpdated: timeUpdated)
        case "step-start":
            return LatestPart(status: .thinking, action: "思考中…", toolStart: nil, timeUpdated: timeUpdated)
        case "step-finish":
            return LatestPart(status: .done, action: "步骤完成", toolStart: nil, timeUpdated: timeUpdated)
        case "text":
            return LatestPart(status: .responding, action: "回复中…", toolStart: nil, timeUpdated: timeUpdated)
        case "file":
            return LatestPart(status: .done, action: "处理文件", toolStart: nil, timeUpdated: timeUpdated)
        case "patch":
            return LatestPart(status: .done, action: "应用补丁", toolStart: nil, timeUpdated: timeUpdated)
        case "compaction":
            return LatestPart(status: .done, action: "压缩上下文", toolStart: nil, timeUpdated: timeUpdated)
        default:
            return LatestPart(status: .done, action: type.isEmpty ? "完成" : type, toolStart: nil, timeUpdated: timeUpdated)
        }
    }

    private func describeInput(tool: String, input: [String: Any]) -> String {
        for key in ["command", "filePath", "path", "pattern", "query", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty { return firstLine(v, max: 40) }
        }
        if let arr = input["todos"] as? [Any] { return "待办 ×\(arr.count)" }
        return ""
    }
}

// MARK: - File watcher (event-driven via DispatchSource VFS source)

final class FileWatcher {
    private var fd: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private let path: String
    private let handler: () -> Void

    init(path: String, handler: @escaping () -> Void) {
        self.path = path
        self.handler = handler
        openAndWatch()
    }

    private func openAndWatch() {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // WAL absent (just checkpointed); retry shortly
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openAndWatch() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .link])
        src.setEventHandler { [weak self] in
            let data = src.data
            if data.contains(.delete) || data.contains(.rename) {
                self?.restart()
            } else {
                self?.handler()
            }
        }
        src.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { close(f); self?.fd = -1 }
        }
        src.resume()
        source = src
    }

    private func restart() {
        source?.cancel()
        source = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openAndWatch() }
    }
}

// MARK: - Helpers

private func col(_ p: UnsafePointer<UInt8>?) -> String { p.map { String(cString: $0) } ?? "" }
private func int64(_ v: Any?) -> Int64? {
    if let n = v as? NSNumber { return n.int64Value }
    if let i = v as? Int64 { return i }
    if let i = v as? Int { return Int64(i) }
    if let d = v as? Double { return Int64(d) }
    return nil
}
private func parseModelId(_ json: String) -> String? {
    guard let d = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return obj["id"] as? String
}
private func firstLine(_ s: String, max: Int) -> String {
    var line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.count > max { line = String(line.prefix(max)) + "…" }
    return line
}
private func fmtElapsed(from start: Int64?, now: Int64) -> String {
    guard let s = start, s > 0 else { return "" }
    let d = max(0, now - s)
    if d < 60 { return "\(d)s" }
    if d < 3600 { return "\(d/60)m\(d%60)s" }
    return "\(d/3600)h\(d%3600/60)m"
}
private func fmtTokens(_ n: Int64) -> String {
    let k = Double(n) / 1000.0
    if k >= 1000 { return String(format: "%.1fM", k / 1000) }
    if k >= 1 { return String(format: "%.1fk", k) }
    return "\(n)"
}

// MARK: - SwiftUI

private let avatarImage: NSImage? = {
    let dir = "\(NSHomeDirectory())/opencode-widget"
    for name in ["avatar.png", "avatar.jpg", "avatar.jpeg"] {
        let p = "\(dir)/\(name)"
        if FileManager.default.fileExists(atPath: p), let img = NSImage(contentsOfFile: p) {
            return img
        }
    }
    return nil
}()

struct WidgetView: View {
    @ObservedObject var store: ActivityStore
    let nowProvider: () -> Int64

    private var running: Bool { store.activities.contains { $0.status == .running } }
    private var thinking: Bool { store.activities.contains { $0.status == .thinking || $0.status == .responding } }

    private var statusColor: Color {
        if running { return .green }
        if thinking { return .orange }
        return .gray
    }

    private var actionText: String {
        guard let a = store.activities.first else { return "摸鱼中 🐟" }
        if a.status == .running { return "\(a.status.emoji) \(a.action)" }
        return a.action
    }

    private var count: Int { store.activities.count }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // outer glow
                Circle().fill(statusColor.opacity(running ? 0.25 : thinking ? 0.15 : 0.05))
                    .frame(width: 82, height: 82)
                    .blur(radius: 4)
                    .scaleEffect(running ? 1.08 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: running)
                // status ring
                Circle()
                    .stroke(statusColor, lineWidth: running ? 3 : 2)
                    .frame(width: 74, height: 74)
                // avatar fill
                Group {
                    if let img = avatarImage {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Text("🤖").font(.system(size: 34))
                    }
                }
                .frame(width: 66, height: 66)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            // action label
            Text(actionText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(statusColor.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 108)
            if count > 1 {
                Text("+\(count - 1)")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 120, height: 130)
    }
}

// MARK: - Floating panel

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSWindow!
    private let store = ActivityStore()

    func applicationDidFinishLaunching(_: Notification) {
        DispatchQueue.main.async { [weak self] in self?.createPanel() }
    }

    private func createPanel() {
        NSApp.setActivationPolicy(.accessory)
        let size = NSSize(width: 120, height: 130)
        let vf = NSScreen.main!.visibleFrame
        // standard titled window (reliable backing store) styled as floating widget
        let w = NSWindow(
            contentRect: NSRect(x: vf.maxX - size.width - 20, y: vf.maxY - size.height - 20,
                                 width: size.width, height: size.height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: WidgetView(store: store, nowProvider: { Int64(Date().timeIntervalSince1970 * 1000) }))
        hosting.autoresizingMask = [.width, .height]
        w.contentView = hosting
        w.makeKeyAndOrderFront(nil)
        self.panel = w
        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }
}

// MARK: - Entry

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
