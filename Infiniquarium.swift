// Infiniquarium · live wallpaper for macOS
//
// Shows infiniquarium.html behind your desktop icons, on the display you choose. The wallpaper is
// only for looking at: clicks always go to your desktop. "Open in Browser" (the fish in the menu bar)
// opens the same tank in your browser, served by this app to this Mac only. While that tab is open it
// runs the tank and the wallpaper follows it; when the tab is hidden or closed the wallpaper carries on.
//
// The page saves the tank through a message handler; this app writes it to
// ~/Library/Application Support/Infiniquarium/tank.json and hands it back at launch.

import AppKit
import Network
import WebKit

private let bundleID = "com.infiniquarium.wallpaper"

/// A small reference box, so completion handlers can report back without mutating captured locals.
final class Flag { var value = false }

/// A borderless window that lives at the desktop level, under the icons. It never takes clicks or keys.
final class TankWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - A tiny web server for "Open in Browser"

/// HTTP/1.1 on 127.0.0.1 only, one request per connection: enough for one page and its small calls.
final class LinkServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]   // names in lower case
        let body: Data
    }
    struct Response {
        var status: Int
        var type = "text/plain; charset=utf-8"
        var body = Data()
    }
    private enum Parsed { case more, bad, done(Request) }

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var handle: ((Request, @escaping (Response) -> Void) -> Void)?
    var log: ((String) -> Void)?

    /// Listen on the first of `ports` that is free; `ready` gets that port, or nil if none was.
    func start(ports: [UInt16], ready: @escaping (UInt16?) -> Void) {
        guard let p = ports.first, let nwPort = NWEndpoint.Port(rawValue: p) else { ready(nil); return }
        let rest = Array(ports.dropFirst())
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            log?("could not listen on port \(p): \(error.localizedDescription)")
            start(ports: rest, ready: ready)
            return
        }
        let settled = Flag()
        l.stateUpdateHandler = { [weak self] state in
            guard let self = self, !settled.value else { return }
            switch state {
            case .ready:
                settled.value = true
                self.listener = l
                self.port = p
                ready(p)
            case .failed(let error), .waiting(let error):
                settled.value = true
                self.log?("port \(p) unavailable: \(error)")
                l.cancel()
                self.start(ports: rest, ready: ready)
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        l.start(queue: .main)
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self = self else { c.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            switch LinkServer.parse(buf) {
            case .done(let request):
                guard let handle = self.handle else { self.send(c, Response(status: 503)); return }
                handle(request) { [weak self] response in self?.send(c, response) }
            case .bad:
                self.send(c, Response(status: 400))
            case .more:
                if complete || error != nil { c.cancel() } else { self.read(c, buf) }
            }
        }
    }

    private static func parse(_ buf: Data) -> Parsed {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 64 * 1024 ? .bad : .more }
        guard let head = String(data: buf.subdata(in: buf.startIndex..<end.lowerBound), encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .bad }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= 16 * 1024 * 1024 else { return .bad }
        let bodyStart = end.upperBound
        if buf.endIndex - bodyStart < length { return .more }
        let body = buf.subdata(in: bodyStart..<(bodyStart + length))
        let target = String(first[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if let key = kv.first { query[key] = kv.count > 1 ? kv[1] : "" }
            }
        }
        return .done(Request(method: String(first[0]).uppercased(), path: path, query: query, headers: headers, body: body))
    }

    private func send(_ c: NWConnection, _ r: Response) {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                       409: "Conflict", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(r.status) \(reasons[r.status] ?? "OK")\r\n"
        head += "Content-Type: \(r.type)\r\nContent-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n"
        head += "Content-Security-Policy: frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: TankWindow!
    private var web: WKWebView!
    private var statusItem: NSStatusItem!
    private var browserItem: NSMenuItem!
    private var smoothItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let displayMenu = NSMenu()
    private var shown = false
    private var signalSource: DispatchSourceSignal?
    private var firstSaveLogged = false
    private var benchDone = false
    private var coverTimer: Timer?
    private var paused = false
    private var coverStreak = 0
    private var cpuPrev: [Int32: Double] = [:]
    private var cpuPrevTime: Date?
    private let defaults = UserDefaults.standard
    private let fm = FileManager.default

    // the browser tab that has the tank, if one does
    private let link = LinkServer()
    private var ownerTab: String?
    private var lastBeat = Date.distantPast
    private var browserState: String?

    // MARK: - Diagnostics (only when started with --log <file>)

    private lazy var logURL: URL? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--log"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }()

    private func diag(_ line: String) {
        guard let url = logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Places

    private var supportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Infiniquarium", isDirectory: true)
    }
    private var saveURL: URL { supportDir.appendingPathComponent("tank.json") }
    private var agentURL: URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist")
    }
    private var fps: Int { defaults.integer(forKey: "fps") == 60 ? 60 : 30 }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // one tank at a time: if a copy is already running, leave it be
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !defaults.bool(forKey: "loginConfigured") {
            defaults.set(true, forKey: "loginConfigured")
            setStartAtLogin(true)
        }
        diag("launch pid \(me), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), screens \(NSScreen.screens.count)")
        buildWindow()
        buildStatusItem()
        startLink()
        startCoverWatch()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // `pkill Infiniquarium` (used by the installer) quits cleanly, so the tank is saved first
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    // MARK: - Screens

    private func screenID(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    private func chosenScreen() -> NSScreen? {
        let wanted = defaults.integer(forKey: "screen")
        if wanted != 0, let match = NSScreen.screens.first(where: { screenID($0) == wanted }) { return match }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Space taken by the menu bar and the Dock.
    private func insets() -> (top: Double, bottom: Double, left: Double, right: Double) {
        guard let screen = chosenScreen() else { return (0, 0, 0, 0) }
        let f = screen.frame, v = screen.visibleFrame
        return (Double(f.maxY - v.maxY), Double(v.minY - f.minY), Double(v.minX - f.minX), Double(f.maxX - v.maxX))
    }

    @objc private func screensChanged() {
        if let screen = chosenScreen() { window.setFrame(screen.frame, display: true) }
        window.level = NSWindow.Level(rawValue: wallpaperLevel())
        pushSettings()
        rebuildDisplayMenu()
    }

    // MARK: - The tank window

    /// Just above the desktop picture and below the desktop icons. The picture's own level has moved
    /// between macOS versions, so look at what's on screen rather than trusting a constant.
    private func wallpaperLevel() -> Int {
        let base = Int(CGWindowLevelForKey(.desktopWindow))
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        var top = base
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard let layer = info[kCGWindowLayer as String] as? Int, layer < 0 else { continue }
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let pid = info[kCGWindowOwnerPID as String] as? Int ?? 0
                if pid == Int(ProcessInfo.processInfo.processIdentifier) { continue }
                diag("low window: owner=\(owner) layer=\(layer)")
                if layer < icons && layer >= base && (owner == "Dock" || owner.localizedCaseInsensitiveContains("wallpaper")) {
                    top = max(top, layer)
                }
            }
        }
        let level = min(top + 1, icons - 1)
        diag("levels: desktop=\(base) icons=\(icons) wallpaper=\(top) -> tank=\(level)")
        return level
    }

    private func buildWindow() {
        let frame = chosenScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = TankWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: wallpaperLevel())
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isOpaque = true
        w.backgroundColor = NSColor(calibratedRed: 0.012, green: 0.024, blue: 0.02, alpha: 1)
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.userContentController.add(self, name: "iq")
        config.userContentController.addUserScript(bootScript())

        let wv = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.allowsMagnification = false
        wv.allowsBackForwardNavigationGestures = false
        w.contentView = wv

        window = w
        web = wv
        w.setFrame(frame, display: false)
        w.orderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: w)
        diag("window at \(NSStringFromRect(frame))")
        loadPage()
    }

    @objc private func occlusionChanged() {
        diag("tank window visible: \(window.occlusionState.contains(.visible))")
    }

    private func loadPage() {
        guard let html = Bundle.main.url(forResource: "infiniquarium", withExtension: "html") else {
            NSLog("Infiniquarium: infiniquarium.html is missing from the app bundle")
            return
        }
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    /// Runs before the page's own scripts: tells it it's a wallpaper and hands it the saved tank.
    private func bootScript() -> WKUserScript {
        var boot = "null"
        if let data = try? Data(contentsOf: saveURL),
           let text = String(data: data, encoding: .utf8),
           let json = try? JSONSerialization.data(withJSONObject: [text], options: []),
           let literal = String(data: json, encoding: .utf8) {
            boot = literal + "[0]"
        }
        let i = insets()
        let source = "window.__IQ_HOST = { kind: 'wallpaper', fps: \(fps), interactive: false, "
            + "diag: \(logURL != nil && !benchDone ? "true" : "false"), "
            + "insets: { top: \(i.top), bottom: \(i.bottom), left: \(i.left), right: \(i.right) }, boot: \(boot) };"
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private func run(_ js: String) {
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func pushSettings() {
        let i = insets()
        run("window.Infiniquarium && (Infiniquarium.setFps(\(fps)), "
            + "Infiniquarium.setInsets({top: \(i.top), bottom: \(i.bottom), left: \(i.left), right: \(i.right)}), "
            + "Infiniquarium.setPaused && Infiniquarium.setPaused(\(paused ? "true" : "false")), "
            + "Infiniquarium.setMirror && Infiniquarium.setMirror(\(ownerTab != nil ? "true" : "false")))")
    }

    // MARK: - Covered by windows

    /// While app windows hide the whole desktop there is nothing to see, so the tank stops drawing
    /// (its clock keeps going). The window list gives positions without needing any permission.
    private func startCoverWatch() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkCover() }
        RunLoop.main.add(t, forMode: .common)
        coverTimer = t
    }

    private func checkCover() {
        // a browser tab that has gone quiet (closed without saying so, or the Mac slept) gives the tank back
        if ownerTab != nil && Date().timeIntervalSince(lastBeat) > 20 { handBack("no word from the tab for 20 s") }
        let (fraction, owners) = coveredFraction()
        let hidden = fraction >= 0.985
        coverStreak = hidden ? coverStreak + 1 : 0
        // a diagnostics run (--log) measures drawing first, so it doesn't pause until that's done
        let want = hidden && coverStreak >= 2 && (logURL == nil || benchDone)
        guard want != paused else { return }
        paused = want
        run("window.Infiniquarium && Infiniquarium.setPaused && Infiniquarium.setPaused(\(want ? "true" : "false"))")
        diag(want ? "desktop covered (\(Int(fraction * 100))% by \(owners.joined(separator: ", "))): paused drawing"
                  : "desktop visible again (\(Int(fraction * 100))% covered): drawing")
    }

    /// Share of the desktop (below the menu bar, beside the Dock) hidden by ordinary app windows.
    private func coveredFraction() -> (Double, [String]) {
        guard let screen = chosenScreen() else { return (0, []) }
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let v = screen.visibleFrame
        let area = CGRect(x: v.minX, y: mainH - v.maxY, width: v.width, height: v.height)   // Quartz: top-left origin
        guard area.width > 0, area.height > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return (0, []) }
        let cols = 48, rows = 27
        let ax = Double(area.minX), ay = Double(area.minY)
        let cw = Double(area.width) / Double(cols), ch = Double(area.height) / Double(rows)
        var hit = [Bool](repeating: false, count: cols * rows)
        var owners = Set<String>()
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < 20 else { continue }
            if (info[kCGWindowOwnerPID as String] as? Int) == me { continue }
            if let a = info[kCGWindowAlpha as String] as? Double, a < 0.9 { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            // see-through system layers, and the overlay of a remote-control helper
            if owner == "Window Server" || owner == "Dock" || owner.localizedCaseInsensitiveContains("cua driver") { continue }
            guard let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            let x = r.intersection(area)
            if x.isNull || x.width < 1 || x.height < 1 { continue }
            let i0 = max(0, Int(ceil((Double(x.minX) - ax) / cw - 0.5))), i1 = min(cols - 1, Int(floor((Double(x.maxX) - ax) / cw - 0.5)))
            let j0 = max(0, Int(ceil((Double(x.minY) - ay) / ch - 0.5))), j1 = min(rows - 1, Int(floor((Double(x.maxY) - ay) / ch - 0.5)))
            if i0 > i1 || j0 > j1 { continue }
            owners.insert(logURL == nil ? owner : "\(owner)[\(layer)] \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))")
            for j in j0...j1 { for i in i0...i1 { hit[j * cols + i] = true } }
        }
        let n = hit.reduce(0) { $0 + ($1 ? 1 : 0) }
        return (Double(n) / Double(cols * rows), owners.sorted())
    }

    // MARK: - Open in Browser

    /// A private key in every link and request, so only the page this app hands out can reach the tank.
    private lazy var linkKey: String = {
        if let k = defaults.string(forKey: "linkKey"), k.count >= 32 { return k }
        let k = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(k, forKey: "linkKey")
        return k
    }()

    private var linkURL: URL? {
        link.port == 0 ? nil : URL(string: "http://127.0.0.1:\(link.port)/?k=\(linkKey)")
    }

    private lazy var pageHTML: String? = {
        guard let url = Bundle.main.url(forResource: "infiniquarium", withExtension: "html") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func startLink() {
        link.log = { [weak self] line in self?.diag("link: \(line)") }
        link.handle = { [weak self] request, reply in
            guard let self = self else { reply(LinkServer.Response(status: 503)); return }
            self.serve(request, reply)
        }
        var ports: [UInt16] = []
        let saved = defaults.integer(forKey: "linkPort")
        if saved > 1024 && saved < 65536 { ports.append(UInt16(saved)) }
        for p in UInt16(47823)...UInt16(47832) where !ports.contains(p) { ports.append(p) }
        link.start(ports: ports) { [weak self] port in
            guard let self = self else { return }
            if let port = port {
                self.defaults.set(Int(port), forKey: "linkPort")
                self.diag("browser link ready on port \(port)")
            } else {
                self.diag("browser link: no free port")
            }
            self.refreshMenu()
        }
    }

    private func serve(_ r: LinkServer.Request, _ reply: @escaping (LinkServer.Response) -> Void) {
        // only from this Mac, only from this page, only with the key from the menu's link
        let here = ["127.0.0.1:\(link.port)", "localhost:\(link.port)"]
        guard here.contains((r.headers["host"] ?? "").lowercased()) else { reply(LinkServer.Response(status: 403)); return }
        if let origin = r.headers["origin"], !here.map({ "http://" + $0 }).contains(origin.lowercased()) {
            reply(LinkServer.Response(status: 403)); return
        }
        guard let key = r.query["k"], key == linkKey else { reply(LinkServer.Response(status: 403)); return }
        let tab = r.query["tab"] ?? ""
        switch (r.method, r.path) {
        case ("GET", "/"):
            reply(pageResponse())
        case ("GET", "/state"):
            currentState { text in
                if let text = text {
                    reply(LinkServer.Response(status: 200, type: "application/json; charset=utf-8", body: Data(text.utf8)))
                } else {
                    reply(LinkServer.Response(status: 503))
                }
            }
        case ("POST", "/claim"):
            takeOver(tab)
            reply(LinkServer.Response(status: 204))
        case ("POST", "/beat"):
            if ownerTab == nil { takeOver(tab) }   // back after a pause; nobody else has it
            if ownerTab == tab { lastBeat = Date(); reply(LinkServer.Response(status: 204)) }
            else { reply(LinkServer.Response(status: 409)) }
        case ("POST", "/state"):
            if let owner = ownerTab, owner != tab { reply(LinkServer.Response(status: 409)); return }
            browserSaved(r.body, tab: tab)
            reply(LinkServer.Response(status: 204))
        case ("POST", "/release"):
            if ownerTab == tab { handBack("the tab let go") }
            reply(LinkServer.Response(status: 204))
        default:
            reply(LinkServer.Response(status: 404))
        }
    }

    private func pageResponse() -> LinkServer.Response {
        guard var html = pageHTML else { return LinkServer.Response(status: 404) }
        let script = "<script>window.__IQ_LINK = { key: \"\(linkKey)\" };</script>"
        if let r = html.range(of: "<head>") { html.insert(contentsOf: script, at: r.upperBound) } else { html = script + html }
        return LinkServer.Response(status: 200, type: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    /// The tank as it is now: from the tab that has it, or from the wallpaper.
    private func currentState(_ done: @escaping (String?) -> Void) {
        if ownerTab != nil, let s = browserState { done(s); return }
        web.evaluateJavaScript("window.Infiniquarium && Infiniquarium.stateString ? Infiniquarium.stateString() : null") { [weak self] result, _ in
            if let s = result as? String, !s.isEmpty { done(s); return }
            done(self.flatMap { try? String(contentsOf: $0.saveURL, encoding: .utf8) })
        }
    }

    private func takeOver(_ tab: String) {
        lastBeat = Date()
        if ownerTab == tab { return }
        let first = ownerTab == nil
        ownerTab = tab
        if first {
            diag("a browser tab took the tank")
            run("window.Infiniquarium && Infiniquarium.setMirror && Infiniquarium.setMirror(true)")
        } else {
            diag("another browser tab took the tank")
        }
    }

    private func handBack(_ why: String) {
        guard ownerTab != nil else { return }
        ownerTab = nil
        diag("the browser tab handed the tank back (\(why))")
        run("window.Infiniquarium && Infiniquarium.setMirror && Infiniquarium.setMirror(false)")
    }

    /// The tab's newest tank: keep it on disk and show it on the wallpaper.
    private func browserSaved(_ body: Data, tab: String) {
        guard let text = String(data: body, encoding: .utf8), text.hasPrefix("{\"v\":1") else { return }
        if ownerTab == tab { lastBeat = Date() }
        browserState = text
        do { try body.write(to: saveURL, options: .atomic) }
        catch { NSLog("Infiniquarium: could not save the tank: \(error.localizedDescription)") }
        if let json = try? JSONSerialization.data(withJSONObject: [text], options: []),
           let literal = String(data: json, encoding: .utf8) {
            run("window.Infiniquarium && Infiniquarium.mirrorState && Infiniquarium.mirrorState(\(literal)[0])")
        }
    }

    @objc private func openInBrowser() {
        guard let url = linkURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// With --log: call the server the way a tab would and record what comes back.
    private func linkSelfTest() {
        guard let base = linkURL else { diag("link test: no server"); return }
        let k = linkKey, port = link.port
        func url(_ path: String, _ tab: String = "selftest") -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)?k=\(k)&tab=\(tab)")!
        }
        func call(_ method: String, _ u: URL, body: Data? = nil, origin: String? = nil, then: @escaping (Int, Data) -> Void) {
            var r = URLRequest(url: u)
            r.httpMethod = method
            r.httpBody = body
            r.timeoutInterval = 8
            if let o = origin { r.setValue(o, forHTTPHeaderField: "Origin") }
            URLSession.shared.dataTask(with: r) { data, response, _ in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async { then(code, data ?? Data()) }
            }.resume()
        }
        let status = "JSON.stringify({ mirror: Infiniquarium.status().mirror, t: Infiniquarium.status().t })"
        call("GET", base) { code, page in
            self.diag("link test: page \(code), \(page.count) bytes, link script \(String(data: page, encoding: .utf8)?.contains("__IQ_LINK") == true)")
            call("GET", URL(string: "http://127.0.0.1:\(port)/state?k=wrong")!) { code, _ in
                self.diag("link test: wrong key -> \(code)")
                call("GET", url("/state"), origin: "https://example.com") { code, _ in
                    self.diag("link test: request from another site -> \(code)")
                    call("GET", url("/state")) { code, state in
                        self.diag("link test: state \(code), \(state.count) bytes")
                        call("POST", url("/claim")) { code, _ in
                            self.diag("link test: claim \(code)")
                            call("POST", url("/state"), body: state) { code, _ in
                                self.diag("link test: send state back \(code)")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    self.web.evaluateJavaScript(status) { r, _ in
                                        self.diag("link test: wallpaper while a tab has it: \(r as? String ?? "?")")
                                        call("POST", url("/beat", "othertab")) { code, _ in
                                            self.diag("link test: a second tab's heartbeat -> \(code)")
                                            call("POST", url("/release")) { code, _ in
                                                self.diag("link test: release \(code)")
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                    self.web.evaluateJavaScript(status) { r, _ in
                                                        self.diag("link test: wallpaper afterwards: \(r as? String ?? "?")")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Page → app

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        switch type {
        case "save":
            if let text = body["s"] as? String {
                do {
                    try Data(text.utf8).write(to: saveURL, options: .atomic)
                    if !firstSaveLogged { firstSaveLogged = true; diag("saved tank (\(text.utf8.count) bytes)") }
                } catch { NSLog("Infiniquarium: could not save the tank: \(error.localizedDescription)") }
            }
        case "ready":
            diag("page ready")
            pushSettings()
        case "diag":
            guard logURL != nil, let text = body["s"] as? String else { break }
            diag("page: \(text)")
            sampleCPU(text.components(separatedBy: " {").first ?? text)
            if text == "bench finished" {
                benchDone = true
                let (f, o) = coveredFraction()
                diag("desktop \(Int(f * 100))% covered by: \(o.joined(separator: "; "))")
                perform(#selector(runLinkSelfTest), with: nil, afterDelay: 2)
                perform(#selector(writeDiagnostics), with: nil, afterDelay: 20)
            }
        default:
            break
        }
    }

    @objc private func runLinkSelfTest() { linkSelfTest() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !shown {
            shown = true
            window.orderFront(nil)
        }
        diag("page loaded; window visible: \(window.occlusionState.contains(.visible))")
        pushSettings()
        if logURL != nil {
            if let pid = webProcessID() { diag("web content pid \(pid)") }
            sampleCPU("page loaded")
            perform(#selector(diagnosticsFallback), with: nil, afterDelay: 90)
        }
    }

    /// The page's WebKit process (WebKit exposes this on WKWebView, though not publicly).
    private func webProcessID() -> Int32? {
        let sel = NSSelectorFromString("_webProcessIdentifier")
        guard web.responds(to: sel), let n = web.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        return n.int32Value
    }

    /// With --log: CPU used by this app and by WebKit's helper processes since the previous sample.
    private func sampleCPU(_ label: String) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,time=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { diag("cpu: ps failed: \(error.localizedDescription)"); return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while ps.isRunning { usleep(2000) }   // not waitUntilExit(): that runs the run loop and lets messages in mid-sample
        guard let text = String(data: data, encoding: .utf8) else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let ours = webProcessID()
        var now: [Int32: Double] = [:]
        var names: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let comm = String(parts[2])
            let name = (comm as NSString).lastPathComponent
            guard pid == me || name.hasPrefix("com.apple.WebKit") || name == "WindowServer" else { continue }
            // [[dd-]hh:]mm:ss.cc
            var secs = 0.0
            var field = String(parts[1])
            if let dash = field.firstIndex(of: "-") { secs += (Double(field[..<dash]) ?? 0) * 86400; field = String(field[field.index(after: dash)...]) }
            var mult = 1.0
            for piece in field.split(separator: ":").reversed() { secs += (Double(piece) ?? 0) * mult; mult *= 60 }
            now[pid] = secs
            let short = name.replacingOccurrences(of: "com.apple.WebKit.", with: "")
            names[pid] = pid == me ? "app" : (pid == ours ? "\(short)(ours)" : short)
        }
        let t = Date()
        if let t0 = cpuPrevTime {
            let dt = t.timeIntervalSince(t0)
            if dt > 0.5 {
                var out: [String] = []
                for pid in now.keys.sorted() {
                    guard let s0 = cpuPrev[pid], let s1 = now[pid] else { continue }
                    let pct = (s1 - s0) / dt * 100
                    if pct >= 0.5 || pid == me || pid == ours { out.append("\(names[pid] ?? "?")[\(pid)] \(String(format: "%.0f", pct))%") }
                }
                diag("cpu over \(String(format: "%.1f", dt))s before '\(label)': " + out.joined(separator: ", "))
            }
        }
        cpuPrev = now
        cpuPrevTime = t
    }

    @objc private func diagnosticsFallback() {
        if !benchDone { writeDiagnostics() }
    }

    /// With --log: record how the page is running and save a picture of it next to the log.
    @objc private func writeDiagnostics() {
        sampleCPU("settled")
        web.evaluateJavaScript("JSON.stringify(window.Infiniquarium ? Infiniquarium.status() : null)") { [weak self] result, error in
            self?.diag("status: \(result as? String ?? String(describing: error))")
        }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 1440)
        web.takeSnapshot(with: config) { [weak self] image, error in
            guard let self = self, let dir = self.logURL?.deletingLastPathComponent() else { return }
            guard let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                self.diag("snapshot failed: \(String(describing: error))")
                return
            }
            try? png.write(to: dir.appendingPathComponent("wallpaper-snapshot.png"))
            self.diag("snapshot saved (\(png.count) bytes), window visible: \(self.window.occlusionState.contains(.visible))")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        diag("page failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        diag("page failed to start: \(error.localizedDescription)")
    }

    /// WebKit may reclaim the page's process after long uptimes; bring the tank straight back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        diag("web content process ended; reloading")
        reloadPage()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            var image: NSImage?
            if #available(macOS 11.0, *) {
                image = NSImage(systemSymbolName: "fish", accessibilityDescription: "Infiniquarium")
                    ?? NSImage(systemSymbolName: "drop", accessibilityDescription: "Infiniquarium")
            }
            if let image = image {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "≈"
            }
            button.toolTip = "Infiniquarium"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Infiniquarium", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        browserItem = item("Open in Browser", #selector(openInBrowser), key: "o")
        menu.addItem(browserItem)
        menu.addItem(.separator())
        smoothItem = item("Smoother Motion (60 fps)", #selector(toggleSmooth))
        menu.addItem(smoothItem)
        let displays = NSMenuItem(title: "Show On", action: nil, keyEquivalent: "")
        displays.submenu = displayMenu
        menu.addItem(displays)
        menu.addItem(.separator())

        loginItem = item("Start at Login", #selector(toggleLogin))
        menu.addItem(loginItem)
        menu.addItem(item("Reload Tank", #selector(reloadTank)))
        menu.addItem(item("Show Saved Tank in Finder", #selector(showSavedTank)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Infiniquarium", #selector(quit), key: "q"))

        menu.delegate = self
        statusItem.menu = menu
        refreshMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        browserItem?.isEnabled = linkURL != nil
        smoothItem?.state = fps == 60 ? .on : .off
        loginItem?.state = fm.fileExists(atPath: agentURL.path) ? .on : .off
        rebuildDisplayMenu()
    }

    private func rebuildDisplayMenu() {
        displayMenu.removeAllItems()
        let current = chosenScreen().map { screenID($0) } ?? 0
        for (index, screen) in NSScreen.screens.enumerated() {
            var name = "Display \(index + 1)"
            if #available(macOS 10.15, *) { name = screen.localizedName }
            let it = item(name, #selector(pickScreen(_:)))
            it.tag = screenID(screen)
            it.state = it.tag == current ? .on : .off
            displayMenu.addItem(it)
        }
    }

    // MARK: - Actions

    @objc private func toggleSmooth() {
        defaults.set(fps == 60 ? 30 : 60, forKey: "fps")
        run("window.Infiniquarium && Infiniquarium.setFps(\(fps))")
    }

    @objc private func pickScreen(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "screen")
        screensChanged()
    }

    @objc private func toggleLogin() {
        setStartAtLogin(!fm.fileExists(atPath: agentURL.path))
    }

    /// A per-user LaunchAgent that starts the app when you log in.
    private func setStartAtLogin(_ on: Bool) {
        if on {
            let exe = Bundle.main.executablePath ?? (Bundle.main.bundlePath + "/Contents/MacOS/Infiniquarium")
            let plist: [String: Any] = [
                "Label": bundleID,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: agentURL, options: .atomic)
            } catch {
                NSLog("Infiniquarium: could not set up Start at Login: \(error.localizedDescription)")
            }
        } else {
            try? fm.removeItem(at: agentURL)
        }
    }

    @objc private func reloadTank() {
        // save first, so the reloaded page picks up exactly where this one was
        run("window.Infiniquarium && Infiniquarium.save()")
        perform(#selector(reloadPage), with: nil, afterDelay: 0.4)
    }

    @objc private func reloadPage() {
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(bootScript())
        loadPage()
    }

    @objc private func showSavedTank() {
        if fm.fileExists(atPath: saveURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([saveURL])
        } else {
            NSWorkspace.shared.open(supportDir)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Give the page a moment to save before the app goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let web = web else { return .terminateNow }
        let done = Flag()
        web.evaluateJavaScript("window.Infiniquarium && Infiniquarium.save()") { _, _ in done.value = true }
        let deadline = Date().addingTimeInterval(0.8)
        while !done.value && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // the save arrives as a separate message; let it land
        let settle = Date().addingTimeInterval(0.2)
        while Date() < settle {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
