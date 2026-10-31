import Cocoa
import ApplicationServices
import IOKit
import ServiceManagement
import UniformTypeIdentifiers
import ScreenCaptureKit

// OneManCursor: resident app for swipe gestures in Finder (prototype)
// - Two-finger horizontal flick → Back (⌘[) / Forward (⌘])
// - Three-finger swipe down → enclosing folder (⌘↑), three-finger swipe up → Open (⌘O)
// Only active while Finder is frontmost. Finger motion is read directly via MultitouchSupport (private).

/// Build number (for checking the version; bump it when behavior changes)
let buildTag = "Build 20261031-70"

// MARK: - MultitouchSupport types (definitions known in the community)

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var position: MTPoint; var velocity: MTPoint }
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32          // 3 = touched, 4 = touching
    var finger: Int32
    var hand: Int32
    var normalized: MTReadout // position normalized to 0...1 (y is positive upward)
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

typealias MTContactCallback = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

func mtCallback(_ device: Int32, _ fingers: UnsafeMutableRawPointer?, _ count: Int32, _ timestamp: Double, _ frame: Int32) {
    Engine.shared.noteFrame(rawCount: Int(count), timestamp: timestamp)
    guard let fingers = fingers, count > 0 else {
        Engine.shared.handle([], timestamp: timestamp)
        return
    }
    let typed = fingers.assumingMemoryBound(to: Finger.self)
    Engine.shared.handle(Array(UnsafeBufferPointer(start: typed, count: Int(count))), timestamp: timestamp)
}

enum SwipeAction: String {
    case back = "Back"
    case forward = "Forward"
    case parent = "Up one level"
    case open = "Open"

    /// Name of the signal sent for partner sync
    var wire: String {
        switch self {
        case .back: return "back"
        case .forward: return "forward"
        case .parent: return "parent"
        case .open: return "open"
        }
    }

    static func fromWire(_ wire: String) -> SwipeAction? {
        switch wire {
        case "back": return .back
        case "forward": return .forward
        case "parent": return .parent
        case "open": return .open
        default: return nil
        }
    }
}

// MARK: - Detection engine

final class Engine {
    static let shared = Engine()
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var remoteMode = UserDefaults.standard.bool(forKey: "remoteMode")

    /// Whether a remote-control app is frontmost. Any app that forwards key input to the other machine
    /// makes swipes work the same way as Moonlight, so the main such apps are covered
    static func isRemoteApp(_ app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        let names = ["Moonlight", "VNC Viewer", "Windows App", "Microsoft Remote Desktop",
                     "Splashtop", "AnyDesk", "TeamViewer", "Jump Desktop"]
        if let n = app.localizedName, names.contains(n) { return true }
        let bids = ["com.moonlight-stream.Moonlight", "com.realvnc.VNCViewer",
                    "com.microsoft.rdc.macos", "com.microsoft.rdc.mac",
                    "com.splashtop.Splashtop", "com.teamviewer.TeamViewer",
                    "com.anydesk.AnyDesk", "com.p5sys.jump.mac.viewer"]
        if let b = app.bundleIdentifier, bids.contains(b) { return true }
        return false
    }
    var linkMode = UserDefaults.standard.bool(forKey: "linkMode")
    var keyTapSession = UserDefaults.standard.bool(forKey: "keyTapSession")
    var onAction: ((String) -> Void)?
    var onStats: ((Int, Int) -> Void)?

    // For diagnostics: whether callbacks are arriving and whether the finger count is readable
    private(set) var frames = 0
    private(set) var maxFingers = 0
    private var lastStatsPush: Double = 0
    private var windowFrames = 0   // For monitoring: frame count in the latest aggregation window
    private var windowMax = 0      // For monitoring: max finger count in the latest aggregation window

    func noteFrame(rawCount: Int, timestamp: Double) {
        frames += 1
        windowFrames += 1
        if rawCount > maxFingers { maxFingers = rawCount }
        if rawCount > windowMax { windowMax = rawCount }
        if timestamp - lastStatsPush > 0.25 {
            lastStatsPush = timestamp
            let f = frames, m = maxFingers
            DispatchQueue.main.async { [weak self] in self?.onStats?(f, m) }
        }
    }

    /// For monitoring: returns (frame count, max finger count) since the last call, then resets
    func takeWindowStats() -> (Int, Int) {
        defer { windowFrames = 0; windowMax = 0 }
        return (windowFrames, windowMax)
    }

    private var session = false
    private var lockedCount = 0       // Max finger count seen during the session (2 or 3)
    private var lockStableSince: Double = 0   // Time the count last increased (to wait for late-touching fingers)
    private var startX: Float = 0, startY: Float = 0
    private var startT: Double = 0
    private var fired = false
    private var lastDx: Float = 0, lastDy: Float = 0   // For diagnostics: last movement seen
    private var horizLatch = false   // Browser push gesture: keep horizontal intent once grabbed
    private var prevCx: Float = 0, prevCy: Float = 0   // Previous-frame centroid, for instantaneous motion

    // Thresholds (as a fraction of normalized coordinates 0...1)
    private let flickMin: Float = 0.20     // Minimum travel for a two-finger flick
    private let vertMin: Float = 0.20      // Minimum travel for three fingers
    private let flickMaxTime = 0.6         // Two fingers: only pick up large movements within this time
    private let graceTime = 0.09           // Time to wait for a late third finger

    func handle(_ fingers: [Finger], timestamp: Double) {
        let downs = fingers.filter { $0.state == 3 || $0.state == 4 }
        if downs.isEmpty {
            if session && !fired && lockedCount >= 3 {
                NetLog.shared.log("Gesture not recognized: \(lockedCount) fingers dy=\(lastDy) dx=\(lastDx)")
            }
            if session { CursorShare.shared.releaseScrollSuppress() }
            horizLatch = false
            session = false; fired = false; lockedCount = 0; return
        }
        let n = downs.count
        let cx = downs.reduce(Float(0)) { $0 + $1.normalized.position.x } / Float(n)
        let cy = downs.reduce(Float(0)) { $0 + $1.normalized.position.y } / Float(n)

        if !session {
            guard n >= 2 else { return }
            CursorShare.shared.clearScrollSuppress()
            prevCx = cx; prevCy = cy
            session = true; lockedCount = n; lockStableSince = timestamp
            startX = cx; startY = cy; startT = timestamp; fired = false
            return
        }
        if n > lockedCount { lockedCount = n; lockStableSince = timestamp }
        guard !fired, n >= 2 else { return }
        let dx = cx - startX, dy = cy - startY
        lastDx = dx; lastDy = dy
        let elapsed = timestamp - startT

        if lockedCount == 2 {
            // When the target is a browser, also pick up a horizontal "push" as back/forward
            // (Chrome swipes are slower and longer than flicks, so the normal flick detection misses them).
            // Detection uses the finger motion itself, so the rebound after lifting (momentum scroll) is not mixed in
            if CursorShare.shared.sessionActiveAway, CursorShare.shared.remoteIsBrowser {
                // Decide "is it a horizontal swipe?" first: look at instantaneous motion, not the cumulative total.
                // Not dragged by early vertical drift; commit to horizontal as soon as horizontal momentum appears
                let vx = cx - prevCx, vy = cy - prevCy
                prevCx = cx; prevCy = cy
                if abs(vx) >= 0.005, abs(vx) >= 2 * abs(vy) { horizLatch = true }
                if abs(vy) >= 0.005, abs(vy) >= 2 * abs(vx) { horizLatch = false }
                if horizLatch { CursorShare.shared.engageScrollSuppress() }
                if horizLatch, abs(dx) >= 0.15, abs(dx) >= 1.2 * abs(dy), elapsed <= 1.5 {
                    fire(dx > 0 ? .back : .forward)
                    return
                }
            }
            // Horizontal flick: right = back, left = forward (same direction as Safari)
            guard elapsed >= graceTime, elapsed <= flickMaxTime else { return }
            if abs(dx) >= flickMin, abs(dx) >= 2 * abs(dy) {
                fire(dx > 0 ? .back : .forward)
            }
        } else if lockedCount == 3 {
            // Vertical: down = enclosing folder, up = open
            // A fourth finger may touch late, so don't fire until the count is stable.
            // Without waiting, a four-finger swipe would be mistaken for three fingers and hijacked
            if timestamp - lockStableSince >= graceTime, abs(dy) >= vertMin, abs(dy) >= 2 * abs(dx) {
                let front = NSWorkspace.shared.frontmostApplication
                let finderContext = front?.bundleIdentifier == "com.apple.finder"
                    || (remoteMode && Self.isRemoteApp(front))
                    || CursorShare.shared.sessionActiveAway
                if enabled && !finderContext {
                    // A three-finger vertical swipe where Finder actions don't apply is routed to switch-sync
                    // (a catch-all for when one finger lightly touched while meaning four; currently an unresponsive input)
                    fired = true
                    let up = dy > 0
                    DispatchQueue.main.async { SwitchSync.shared.noteGesture(up: up) }
                } else {
                    fire(dy > 0 ? .open : .parent)
                }
            }
        } else if lockedCount >= 4 {
            // A four-finger vertical swipe is the Mission Control / Exposé gesture (detection for switch-sync)
            if abs(dy) >= vertMin, abs(dy) >= 2 * abs(dx) {
                fired = true
                let up = dy > 0
                DispatchQueue.main.async { SwitchSync.shared.noteGesture(up: up) }
            }
        }
    }

    private func fire(_ action: SwipeAction) {
        fired = true
        // When it's OK to send: when Finder is frontmost.
        // In remote-control mode, also send when Moonlight is frontmost (keys reach the other side via Moonlight)
        let front = NSWorkspace.shared.frontmostApplication
        let isFinder = front?.bundleIdentifier == "com.apple.finder"
        let isRemote = remoteMode && Self.isRemoteApp(front)
        var note = ""
        if !enabled {
            note = " (disabled)"
        } else if CursorShare.shared.sessionActiveAway {
            // If controlling the other machine via cursor sharing, also send swipes to it as key input.
            // But don't send actions that don't suit the other app (sending ⌘O to Chrome
            // would open a file dialog, for example)
            if CursorShare.shared.swipeAllowedRemotely(action) {
                CursorShare.shared.forwardActionKey(for: action)
                note = " (sent via cursor sharing)"
            } else {
                note = " (not sent: other machine's app)"
            }
        } else if isFinder {
            postKey(for: action)
        } else if isRemote {
            postKey(for: action)
        } else {
            note = " (not sent: not a target app)"
        }
        let label = action.rawValue + note
        DispatchQueue.main.async { [weak self] in self?.onAction?(label) }
    }

    /// When a signal arrives from the partner. Only runs when our own Finder is frontmost
    func receiveLink(_ wire: String) {
        guard enabled, linkMode else { return }
        guard let action = SwipeAction.fromWire(wire) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        NetLog.shared.log("Swipe received \(wire): Finder frontmost=\(front?.bundleIdentifier == "com.apple.finder")")
        guard front?.bundleIdentifier == "com.apple.finder" else { return }
        postKey(for: action)
        let label = "Signal received: \(action.rawValue)"
        DispatchQueue.main.async { [weak self] in self?.onAction?(label) }
    }

    private func postKey(for action: SwipeAction) {
        switch action {
        case .back: sendKey(33)      // [
        case .forward: sendKey(30)   // ]
        case .parent: sendKey(126)   // ↑
        case .open: sendKey(31)      // O
        }
    }

    private func sendKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // The send method can be switched, to explore which path Universal Control picks up
        let tap: CGEventTapLocation = keyTapSession ? .cgSessionEventTap : .cghidEventTap
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) {
                e.flags = .maskCommand
                e.post(tap: tap)
            }
        }
    }
}

// MARK: - Partner sync (exchanging signals within the same network)

// Universal Control only forwards "real keyboard input" to the other side,
// and keys synthesized by the app didn't arrive with either send method (confirmed on real hardware).
// So only the swipe "signal" is sent via UDP broadcast,
// and the receiving OneManCursor sends the key to its own Finder.
// Note: anyone on the same LAN can send signals — a prototype design (assumes home use).
enum LinkNet {
    static let port: UInt16 = 45987
    private static let magic = "FSWIPE1 "
    private static var seenSeqs: [UInt64: Double] = [:]
    private static var seenFast: [String: Double] = [:]
    private static var fastSeq: UInt64 = 0
    private static var sendFd: Int32 = -1
    private static let sendQueue = DispatchQueue(label: "finderswipe.send")
    private static var pendingTarget: String?
    private static var pendingDx = 0
    private static var pendingDy = 0
    private static var flushScheduled = false

    /// Discovered partners (id → name, IP, last-seen time)
    private(set) static var peers: [String: (name: String, ip: String, seen: Date)] = [:]
    /// The other machine's screen size (reported in hello; used for tile proportions in the layout editor)
    static var peerSizes: [String: (w: Int, h: Int)] = [:]

    // Direct TCP connection (delivery and ordering are guaranteed, so this is the main fix for dropped keys)
    static let tcpPort: UInt16 = 45988
    private static var conns: [String: TcpConn] = [:]
    private static let connsLock = NSLock()

    final class TcpConn {
        let fd: Int32
        private let writeLock = NSLock()
        init(fd: Int32) { self.fd = fd }
        func sendLine(_ line: String) -> Bool {
            writeLock.lock()
            defer { writeLock.unlock() }
            let bytes = Array((line + "\n").utf8)
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBytes { buf in
                    Darwin.send(fd, buf.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                }
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        func close() {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    /// Send over TCP to all connected partners (peers not connected are picked up via UDP)
    private static func sendToAllPeers(_ text: String) {
        connsLock.lock()
        let list = Array(conns.values)
        connsLock.unlock()
        for c in list { _ = c.sendLine(text) }
    }

    /// Start announcing ourselves (so partners can be found in layout settings)
    static func startHello() {
        hello()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in hello() }
    }

    private static func hello() {
        let name = Host.current().localizedName ?? "Mac"
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let w = union.width > 0 ? Int(union.width) : 1920
        let h = union.height > 0 ? Int(union.height) : 1080
        udpSend(magic + "\(machineID) 0 hello \(name) \(w)x\(h)")
    }

    /// Full reset of the cursor-sharing session
    static func sendReset() {
        let text = magic + "\(machineID) 0 reset"
        sendToAllPeers(text)
        udpSend(text)
    }

    /// Our own identifier (so we don't receive signals we sent ourselves)
    static let machineID: String = {
        if let s = UserDefaults.standard.string(forKey: "machineID") { return s }
        let s = String(UInt32.random(in: 0..<UInt32.max), radix: 16)
        UserDefaults.standard.set(s, forKey: "machineID")
        return s
    }()

    private static func udpSend(_ text: String, toIP ip: String? = nil) {
        // Reuse a single send socket (recreating it for every signal makes mouse movement sluggish)
        if sendFd < 0 {
            sendFd = socket(AF_INET, SOCK_DGRAM, 0)
            guard sendFd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(sendFd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        let payload = Array(text.utf8)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if let ip = ip {
            addr.sin_addr.s_addr = inet_addr(ip)
        } else {
            addr.sin_addr.s_addr = INADDR_BROADCAST
        }
        payload.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(sendFd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Swipe signal (sent to all partners over TCP, and 3 times over UDP for peers that aren't connected)
    static func send(_ wire: String) {
        let seq = UInt64(Date().timeIntervalSince1970 * 1000)
        let text = magic + "\(machineID) \(seq) \(wire)"
        DispatchQueue.global().async {
            sendToAllPeers(text)
            for _ in 0..<3 {
                udpSend(text)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    /// Fine-grained cursor-sharing signals. Sending is offloaded to a dedicated queue, and movement (mv) is batched in ~6 ms chunks
    /// (sending synchronously inside the tap or per event would slow everything down)
    static func sendFast(_ body: String) {
        if !body.hasPrefix("mv ") { NetLog.shared.log("Send " + body) }
        sendQueue.async {
            if body.hasPrefix("mv ") {
                let p = body.split(separator: " ")
                if p.count == 4, let dx = Int(p[2]), let dy = Int(p[3]) {
                    if pendingTarget != String(p[1]) { flushMove() }
                    pendingTarget = String(p[1])
                    pendingDx += dx
                    pendingDy += dy
                    if !flushScheduled {
                        flushScheduled = true
                        sendQueue.asyncAfter(deadline: .now() + 0.006) {
                            flushMove()
                            flushScheduled = false
                        }
                    }
                    return
                }
            }
            flushMove()
            // Dropping "events" such as keys or clicks is fatal. With TCP they arrive reliably in one send;
            // without it, send the same sequence number 3 times over UDP (the receiver discards duplicates)
            rawSend(body, copies: 3)
        }
    }

    private static func flushMove() {
        guard let t = pendingTarget else { return }
        pendingTarget = nil
        if pendingDx != 0 || pendingDy != 0 {
            rawSend("mv \(t) \(pendingDx) \(pendingDy)")
            pendingDx = 0
            pendingDy = 0
        }
    }

    private static func rawSend(_ body: String, copies: Int = 1) {
        fastSeq &+= 1
        let text = magic + "\(machineID) \(fastSeq) \(body)"
        if emitViaTCP(text, body: body) { return }
        // For peers without TCP (such as Windows), send unicast if the IP is known.
        // Wi-Fi broadcast has high latency and loss, which causes stutter and dropped signals
        var ip: String? = nil
        let bparts = body.split(separator: " ")
        if bparts.count >= 2, let info = peers[String(bparts[1])], Date().timeIntervalSince(info.seen) < 20 {
            ip = info.ip
        }
        udpSend(text, toIP: ip)
        if copies > 1 {
            for delay in [0.010, 0.020] {
                sendQueue.asyncAfter(deadline: .now() + delay) { udpSend(text, toIP: ip) }
            }
        }
    }

    /// If TCP-connected to the destination peer, send that way. Returns true if sent
    private static func emitViaTCP(_ text: String, body: String) -> Bool {
        let parts = body.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let target = String(parts[1])
        connsLock.lock()
        let conn = conns[target]
        connsLock.unlock()
        guard let conn = conn else { return false }
        if conn.sendLine(text) { return true }
        connsLock.lock()
        if conns[target] === conn { conns[target] = nil }
        connsLock.unlock()
        return false
    }

    static func startReceiver() {
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { return }
            var buf = [UInt8](repeating: 0, count: 2048)
            while true {
                var src = sockaddr_in()
                var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &src) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, 0, sa, &srcLen)
                    }
                }
                guard n > 0 else { continue }
                let s = String(decoding: buf[0..<n], as: UTF8.self)
                let ip = String(cString: inet_ntoa(src.sin_addr))
                handlePacket(s, ip: ip)
            }
        }
    }

    /// Handle one signal (common to UDP and TCP)
    static func handlePacket(_ s: String, ip: String) {
        guard s.hasPrefix(magic) else { return }
        let parts = s.dropFirst(magic.count).split(separator: " ")
        guard parts.count >= 3, String(parts[0]) != machineID, let seq = UInt64(parts[1]) else { return }
        let kind = String(parts[2])
        if kind == "hello" {
            var tokens = parts.dropFirst(3).map { String($0) }
            // Split off the trailing resolution token (e.g. 2560x1440) since it's not part of the name
            if let last = tokens.last {
                let wh = last.split(separator: "x")
                if wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) {
                    peerSizes[String(parts[0])] = (w, h)
                    tokens.removeLast()
                }
            }
            let name = tokens.joined(separator: " ")
            let dispName = name.isEmpty ? "Mac" : name
            let prev = peers[String(parts[0])]?.seen
            peers[String(parts[0])] = (dispName, ip, Date())
            var names = UserDefaults.standard.dictionary(forKey: "layoutNames") as? [String: String] ?? [:]
            if names[String(parts[0])] != dispName {
                names[String(parts[0])] = dispName
                UserDefaults.standard.set(names, forKey: "layoutNames")
            }
            LayoutStore.noteHello(id: String(parts[0]), prevSeen: prev)
            return
        }
        if kind == "reset" {
            CursorShare.shared.resetFromSignal()
            return
        }
        if SwipeAction.fromWire(kind) != nil {
            // Swipe signal: the same one arriving multiple times over multiple paths is executed only once
            let now = Date().timeIntervalSince1970
            if let seen = seenSeqs[seq], now - seen < 2 { return }
            seenSeqs[seq] = now
            seenSeqs = seenSeqs.filter { now - $0.value < 10 }
            NetLog.shared.log("Received \(kind) from=\(parts[0]) → swipe handling")
            Engine.shared.receiveLink(kind)
        } else {
            // Cursor-sharing signal: sent 3 times over UDP, so process each sequence number only once
            let dupKey = "\(parts[0])-\(seq)"
            let nowFast = Date().timeIntervalSince1970
            if let seen = seenFast[dupKey], nowFast - seen < 2 { return }
            seenFast[dupKey] = nowFast
            seenFast = seenFast.filter { nowFast - $0.value < 10 }
            if kind != "mv" && kind != "dn" && kind != "up" && kind != "sc" && kind != "kd" && kind != "ku" && kind != "fl" { NetLog.shared.log("Received \(kind) from=\(parts[0]) → sharing handling") }
            CursorShare.shared.receive(kind, args: parts.dropFirst(3).map { String($0) }, from: String(parts[0]))
        }
    }

    // MARK: Direct TCP connection

    static func startTCP() {
        // Accepting side
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = tcpPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else { return }
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                configureConn(c)
                DispatchQueue.global().async { serveConn(c, expectedPeer: nil, conn: nil) }
            }
        }
        // Connecting side: to avoid duplicates, the one with the smaller ID connects to the peer
        DispatchQueue.global().async {
            while true {
                let now = Date()
                for (id, info) in peers where machineID < id && now.timeIntervalSince(info.seen) < 20 {
                    connsLock.lock()
                    let has = conns[id] != nil
                    connsLock.unlock()
                    if !has { connectToPeer(id: id, ip: info.ip) }
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    private static func configureConn(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func connectToPeer(id: String, ip: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = tcpPort.bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { close(fd); return }
        configureConn(fd)
        let conn = TcpConn(fd: fd)
        registerConn(conn, for: id)
        let name = Host.current().localizedName ?? "Mac"
        _ = conn.sendLine("FSHELLO \(machineID) \(name)")
        DispatchQueue.global().async { serveConn(fd, expectedPeer: id, conn: conn) }
    }

    private static func registerConn(_ conn: TcpConn, for id: String) {
        connsLock.lock()
        let old = conns[id]
        conns[id] = conn
        connsLock.unlock()
        old?.close()
    }

    /// Read from one connection. Verify the peer with the leading FSHELLO, then process signals line by line
    private static func serveConn(_ fd: Int32, expectedPeer: String?, conn knownConn: TcpConn?) {
        var buffer = ""
        var peerID = expectedPeer
        var conn = knownConn
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer += String(decoding: chunk[0..<n], as: UTF8.self)
            if buffer.count > 65536 { buffer.removeAll() }
            while let range = buffer.range(of: "\n") {
                let line = String(buffer[buffer.startIndex..<range.lowerBound])
                buffer = String(buffer[range.upperBound...])
                if line.hasPrefix("FSHELLO ") {
                    let t = line.dropFirst(8).split(separator: " ", maxSplits: 1)
                    if let first = t.first {
                        peerID = String(first)
                        if conn == nil {
                            let c = TcpConn(fd: fd)
                            conn = c
                            registerConn(c, for: peerID!)
                        }
                    }
                    continue
                }
                if peerID != nil { handlePacket(line, ip: "") }
            }
        }
        if let id = peerID, let c = conn {
            connsLock.lock()
            if conns[id] === c { conns[id] = nil }
            connsLock.unlock()
        }
        close(fd)
    }
}

// MARK: - Cursor sharing (prototype)

func cursorTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    CursorShare.shared.handle(type: type, event: event)
}

/// Direction the partner is in. The layout maps "direction → partner machine ID", so three or more machines can be chained
enum PartnerDir: String {
    case right, left, up, down
    var opposite: PartnerDir {
        switch self {
        case .right: return .left
        case .left: return .right
        case .up: return .down
        case .down: return .up
        }
    }
}

/// Adjacency link: direction + peer + the range (fraction) of our edge that overlaps the peer.
/// With offset layouts only part of an edge overlaps, so a range is kept
struct PeerLink {
    var dir: PartnerDir
    var id: String
    var start: Double
    var end: Double
    /// For saving/distribution ("peerID", or "peerID@start@end" when the range is partial)
    var spec: String {
        if start <= 0.0005 && end >= 0.9995 { return id }
        return "\(id)@\(String(format: "%.3f", start))@\(String(format: "%.3f", end))"
    }
}

/// Cursor-sharing prototype.
/// The originating Mac grabs mouse and keys with an event tap, converts them to addressed signals, and sends them.
/// A receiving Mac reproduces them on its own screen, and relays to the next peer if it crosses an edge that has a neighbor.
/// Esc is the emergency exit: it ends the session on the originator, and signals a full reset on participants.
final class CursorShare {
    static let shared = CursorShare()
    var enabled = UserDefaults.standard.bool(forKey: "cursorShare")
    var onStatus: ((String) -> Void)?

    /// Table of adjacency links (derived from the layout; the place for manual settings too)
    private(set) var links: [PeerLink] = []

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    // Session state (only one at a time)
    private var sending = false      // We are the originator (grabbing input with the tap)
    private var awayTo: String?      // When originator: the peer we've handed the cursor to
    private var holding = false      // The cursor is on our screen (originated elsewhere)
    private var cameFrom: String?    // When holder: the peer who handed it to us
    private var forwardTo: String?   // While relaying: the next peer further on
    private(set) var cursorAtID: String?   // The machine the cursor is currently on (current location shared by all machines)
    private var vx: Double = 0, vy: Double = 0

    // Screen-transition tuning (changed via the "Screen transition tuning" menu)
    /// Edge push amount (px). 0 = move immediately on touching the edge
    /// Solo mode: don't hand the cursor to other machines, and send back any cursor that arrives (so it isn't lost at the screen edge). Set per device
    var soloMode: Bool {
        get { UserDefaults.standard.bool(forKey: "soloMode") }
        set { UserDefaults.standard.set(newValue, forKey: "soloMode") }
    }

    /// Cleanup at the moment of entering solo mode: return a held cursor to its owner, and close any session we handed off
    func enforceSolo() {
        if holding, let from = cameFrom {
            LinkNet.sendFast("leave \(from) 0.5")
            holding = false
            cameFrom = nil
            EdgeGlow.shared.hide()
            status("Solo mode: returned the cursor")
        } else if sending || forwardTo != nil {
            LinkNet.sendReset()
            resetSession()
            status("Solo mode: ended the session")
        }
    }

    static var pushPx: Int { UserDefaults.standard.integer(forKey: "edgePushPx") }
    /// Multiplier for cursor movement sent by the originator. If unset (0), 1
    static var moveMult: Double {
        let v = UserDefaults.standard.double(forKey: "moveMult")
        return v == 0 ? 1 : v
    }
    private var edgePush: [PartnerDir: Double] = [:]   // Originator side: accumulated push against the edge
    private var holdPush: [PartnerDir: Double] = [:]   // Holder side: accumulated push against the edge
    private var multAccX = 0.0, multAccY = 0.0         // Carry over the fractional part of the multiplier

    private init() {
        // Read the new format (linksV2); if absent, migrate from the old format (neighbor_*)
        if let s = UserDefaults.standard.string(forKey: "linksV2") {
            links = Self.parseLinks(s)
        } else {
            var migrated: [PeerLink] = []
            for dir in [PartnerDir.right, .left, .up, .down] {
                if let id = UserDefaults.standard.string(forKey: "neighbor_" + dir.rawValue) {
                    migrated.append(PeerLink(dir: dir, id: id, start: 0, end: 1))
                }
            }
            links = migrated
            if !migrated.isEmpty { saveLinks() }
        }
    }

    /// Restore the link table from the saved/distributed string (format "right=id@0.00@0.50;left=id2")
    static func parseLinks(_ s: String) -> [PeerLink] {
        var out: [PeerLink] = []
        for tok in s.split(separator: ";") {
            let kv = tok.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let d = PartnerDir(rawValue: String(kv[0])),
                  let lk = parseLink(dir: d, spec: String(kv[1])) else { continue }
            out.append(lk)
        }
        return out
    }

    static func parseLink(dir: PartnerDir, spec: String) -> PeerLink? {
        let p = spec.split(separator: "@")
        guard let first = p.first, !first.isEmpty else { return nil }
        var s = 0.0, e = 1.0
        if p.count == 3, let a = Double(p[1]), let b = Double(p[2]) { s = min(a, b); e = max(a, b) }
        return PeerLink(dir: dir, id: String(first), start: s, end: e)
    }

    private func saveLinks() {
        let s = links.map { "\($0.dir.rawValue)=\($0.spec)" }.joined(separator: ";")
        UserDefaults.standard.set(s, forKey: "linksV2")
    }

    /// Replace the whole link table (from layout assignment / the editor)
    func setLinks(_ newLinks: [PeerLink]) {
        links = newLinks
        saveLinks()
    }

    /// Remember a peer arriving via a signal as the neighbor in that direction (auto-learning).
    /// Don't break things if the same peer is already in that direction (including assignments with a span)
    func learnLink(dir: PartnerDir, id: String) {
        if links.contains(where: { $0.dir == dir && $0.id == id }) { return }
        links.removeAll { $0.id == id }
        links.removeAll { $0.dir == dir }
        links.append(PeerLink(dir: dir, id: id, start: 0, end: 1))
        saveLinks()
    }

    /// The link overlapping position ratio on the edge in that direction
    func link(dir: PartnerDir, at ratio: Double) -> PeerLink? {
        links.first { $0.dir == dir && ratio >= $0.start - 0.001 && ratio <= $0.end + 0.001 }
    }

    func link(toPeer id: String) -> PeerLink? { links.first { $0.id == id } }

    func dir(ofPeer id: String) -> PartnerDir? { link(toPeer: id)?.dir }

    /// Convert the "position within the shared edge" received from the peer into a position on our own edge
    func entryRatio(forPeer id: String, seg: Double) -> Double {
        guard let lk = link(toPeer: id) else { return seg }
        return lk.start + seg * (lk.end - lk.start)
    }

    private func peerName(_ id: String) -> String {
        LinkNet.peers[id]?.name ?? "Peer"
    }

    /// Bounding box of all displays (multiple displays are approximated by this box)
    private var allBounds: CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return CGDisplayBounds(CGMainDisplayID()) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        var u = CGDisplayBounds(ids[0])
        for id in ids.dropFirst() { u = u.union(CGDisplayBounds(id)) }
        return u
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "cursorShare")
        if on {
            installTap()
            requestInputAccessIfNeeded()
        } else {
            LinkNet.sendReset()
            resetSession()
            removeTap()
        }
    }

    func resetSession() {
        sending = false
        awayTo = nil
        holding = false
        cameFrom = nil
        forwardTo = nil
        remoteAppID = nil
        remoteAppPeer = nil
        showCursor()
        stopPinning()
        EdgeGlow.shared.hide()
    }

    /// Only for the machine where the emergency exit (⌘Esc) was pressed: bring a lost cursor to the middle of the screen.
    /// Doesn't act on other machines that were merely reset by a signal (to avoid surprising their users)
    func centerCursor() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
        let primaryH = screens[0].frame.height
        // NSScreen has a bottom-left origin and Quartz a top-left origin, so flip using the main screen's height
        let center = CGPoint(x: screen.frame.midX, y: primaryH - screen.frame.midY)
        CGWarpMouseCursorPosition(center)
        // A warp alone leaves the event position off, so also emit one real event
        if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
            Self.markSynthetic(mv)
            mv.post(tap: .cghidEventTap)
        }
        NetLog.shared.log("⌘Esc: moved cursor to screen center")
    }

    /// Handling when reset by a signal. A machine that was in a session also returns its cursor
    /// to the middle (so a distant ⌘Esc can rescue a machine that stopped responding).
    /// A machine that wasn't in a session just tidies up its state (no surprises)
    func resetFromSignal() {
        let wasInSession = sending || holding || forwardTo != nil
        resetSession()
        if wasInSession { centerCursor() }
    }

    private var frozenPoint: CGPoint?
    private var pinTimer: Timer?

    /// While handed off, keep pinning the originator's cursor at the handoff point.
    /// Even where hiding doesn't work (e.g. UC rendering), it at least stops following the hand's motion
    private func startPinning(at point: CGPoint) {
        frozenPoint = point
        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.awayTo != nil, let p = self.frozenPoint else { return }
            CGWarpMouseCursorPosition(p)
            CGAssociateMouseAndMouseCursorPosition(1)
            self.hideCursor()
        }
    }

    private func stopPinning() {
        pinTimer?.invalidate()
        pinTimer = nil
        frozenPoint = nil
    }

    private var cursorHidden = false
    private var hideCount = 0

    /// While control is handed off, hide the originator's cursor (visible, it invites accidental taps).
    /// Clicks themselves are swallowed by the tap and don't reach apps, but we also remove the visual.
    /// Count the hides, and show the same number of times when restoring (since the pin timer hides repeatedly)
    private func hideCursor() {
        for id in activeDisplayIDs() { CGDisplayHideCursor(id) }
        hideCount += 1
        cursorHidden = true
    }

    private func showCursor() {
        while hideCount > 0 {
            for id in activeDisplayIDs() { CGDisplayShowCursor(id) }
            hideCount -= 1
        }
        cursorHidden = false
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [CGMainDisplayID()] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    /// Automatically do only the "registration" for Input Monitoring.
    /// Asking for permission from the app brings up the system prompt and adds it to the settings list automatically (with the switch left off).
    /// Turning the switch on itself can only be done by the user, per macOS rules.
    func requestInputAccessIfNeeded() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    /// Version that explicitly requests permission from the menu. Shows what macOS sees under "Last detection" to help isolate the problem
    func requestInputAccessNow() {
        let before = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        // Attempting to create a HID-level listen-only key tap also triggers registration in the settings list, so use it too
        var probeOK = false
        let keyMask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        if let probe = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                         eventsOfInterest: keyMask,
                                         callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil) {
            probeOK = true
            CGEvent.tapEnable(tap: probe, enable: false)
            CFMachPortInvalidate(probe)
        }
        let label: String
        switch before {
        case kIOHIDAccessTypeGranted: label = "Granted"
        case kIOHIDAccessTypeDenied: label = "Denied (change in Settings required)"
        default: label = "Unknown"
        }
        status("Input Monitoring: \(label) / request \(ok ? "OK" : "NG") / HID tap \(probeOK ? "creatable" : "not creatable")")
    }

    // MARK: Event tap (handling of the originator and physical input while participating)

    func installTap() {
        guard tap == nil else { return }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cursorTapCallback, userInfo: nil) else {
            status("Cursor sharing: couldn't create the tap (check permissions)")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func removeTap() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        tapSource = nil
    }

    private func isMove(_ t: CGEventType) -> Bool {
        t == .mouseMoved || t == .leftMouseDragged || t == .rightMouseDragged || t == .otherMouseDragged
    }

    private func isMouse(_ t: CGEventType) -> Bool {
        isMove(t) || t == .leftMouseDown || t == .leftMouseUp || t == .rightMouseDown || t == .rightMouseUp
            || t == .otherMouseDown || t == .otherMouseUp || t == .scrollWheel
    }

    /// Marker put on events we synthesize (so our own tap doesn't swallow them)
    private static let syntheticMarker: Int64 = 0x4653_5750

    /// Put the marker on a synthesized event (so our own tap doesn't swallow it)
    static func markSynthetic(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Let events we synthesized pass through (so clicks and scrolls posted as the holder
        // aren't dropped by our tap's "swallow the physical mouse while participating" rule)
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }
        // When the cursor is local, update the border display based on proximity to the edge
        if enabled, awayTo == nil, !holding, forwardTo == nil,
           type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            updateGlowAtHome(event.location)
        }
        // The emergency exit is ⌘Esc. Plain Esc is a commonly used key, so send it to the peer as a normal key
        let isEsc = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 && event.flags.contains(.maskCommand)
        // Switch-screen sync: pressing Ctrl+↑ locally means "opened the overview", and Esc during switching means "confirm"
        if type == .keyDown, awayTo == nil, !holding, forwardTo == nil {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == 126, event.flags.contains(.maskControl), !event.flags.contains(.maskCommand) {
                SwitchSync.shared.noteOpenKey()
            } else if kc == 99, !event.flags.contains(.maskCommand) {
                // MC key (F3): when it arrives as a standard key
                SwitchSync.shared.noteOpenKey()
            } else if kc == 53, !event.flags.contains(.maskCommand) {
                SwitchSync.shared.noteLocalEsc()
            }
        }
        // Search sync: pressing ⌘+Space locally makes us the originator, and keystrokes are sent to all machines
        if awayTo == nil, !holding, forwardTo == nil {
            if type == .keyDown {
                let kc = event.getIntegerValueField(.keyboardEventKeycode)
                if kc == 49, event.flags.contains(.maskCommand) {
                    if SearchSync.shared.origin { SearchSync.shared.noteLocalEnd() } else { SearchSync.shared.noteLocalOpen() }
                } else if SearchSync.shared.origin, kc == 53 {
                    // Esc is watched by SearchSync to tell it apart from an IME cancel, then decided
                    SearchSync.shared.forwardKey(keycode: kc)
                } else if SearchSync.shared.origin {
                    // Keystrokes are forwarded to all machines as-is (including Enter)
                    SearchSync.shared.forwardTypedKey(type: type, event: event)
                }
            } else if SearchSync.shared.origin, type == .keyUp || type == .flagsChanged {
                SearchSync.shared.forwardTypedKey(type: type, event: event)
            } else if SearchSync.shared.origin, type == .leftMouseDown || type == .rightMouseDown {
                SearchSync.shared.noteLocalEnd()
            }
        }

        // Participating in a session originated elsewhere (holder/relay): swallow the physical mouse since its position is off. ⌘Esc resets everything
        if holding || forwardTo != nil {
            if isEsc {
                LinkNet.sendReset()
                resetSession()
                centerCursor()
                status("Cursor sharing: reset")
                return nil
            }
            if isMouse(type) { return nil }
            return Unmanaged.passUnretained(event)
        }

        // We are the originator
        if sending {
            if awayTo == nil {
                // The cursor is local: pass events through as usual while watching the edge. ⌘Esc cleans up our own session state
                if isEsc { resetSession(); centerCursor() }
                if isMove(type), checkEdges(event) { return nil }
                return Unmanaged.passUnretained(event)
            }
            // The cursor is on the peer's side: ⌘Esc ends it; anything else is turned into a signal and swallowed
            if isEsc {
                LinkNet.sendReset()
                resetSession()
                centerCursor()
                status("Cursor sharing: ended")
                return nil
            }
            forwardPhysical(type: type, event: event, to: awayTo!)
            return nil
        }

        // Idle: touching an edge starts a session. ⌘Esc acts as "find cursor" and moves it to the middle
        if isEsc { centerCursor() }
        if isMove(type), checkEdges(event) { return nil }
        return Unmanaged.passUnretained(event)
    }

    /// The "peer's frontmost app" known to the originator (app report from the holder; nil if not yet reported)
    private(set) var remoteAppID: String?
    private(set) var remoteAppPeer: String?

    private var appObserver: NSObjectProtocol?

    /// As the holder, tell the originator our frontmost app (for per-app gating of swipes during sharing)
    private func reportFrontApp() {
        guard holding, let to = cameFrom else { return }
        if appObserver == nil {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, self.holding, let dest = self.cameFrom,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bid = app.bundleIdentifier else { return }
                LinkNet.sendFast("app \(dest) \(bid)")
            }
        }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            LinkNet.sendFast("app \(to) \(bid)")
        }
    }

    /// Apps regarded as browsers (for swipe routing during sharing and horizontal-swipe detection)
    private static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Whether the peer's frontmost app is a browser (based on the app report)
    var remoteIsBrowser: Bool {
        guard let bid = remoteAppID, remoteAppPeer == awayTo else { return false }
        return Self.browserIDs.contains(bid)
    }

    // Suppress scroll forwarding during a browser horizontal swipe (operated from the Engine)
    private var scrollSuppressEngaged = false
    private var scrollSuppressUntil = 0.0
    func engageScrollSuppress() {
        scrollSuppressEngaged = true
        scrollSuppressUntil = Date().timeIntervalSince1970 + 0.5
    }
    func releaseScrollSuppress() {
        // Once fingers lift, extend a little until the rebound (momentum scroll) is used up, then release
        if scrollSuppressEngaged { scrollSuppressUntil = Date().timeIntervalSince1970 + 1.2 }
    }
    func clearScrollSuppress() { scrollSuppressEngaged = false; scrollSuppressUntil = 0 }
    var scrollSuppressed: Bool {
        if scrollSuppressEngaged && Date().timeIntervalSince1970 > scrollSuppressUntil { scrollSuppressEngaged = false }
        return scrollSuppressEngaged
    }

    // Axis lock for scroll forwarding: a continuous scroll passes only the axis with momentum
    // (prevents the peer from scrolling up/down due to vertical finger drift when a horizontal swipe was intended)
    private var scAccX = 0.0, scAccY = 0.0, scLastT = 0.0
    private var scLockH: Bool? = nil
    private func axisLockedScroll(dy: Double, dx: Double) -> (Double, Double) {
        let now = Date().timeIntervalSince1970
        if now - scLastT > 0.25 { scAccX = 0; scAccY = 0; scLockH = nil }
        scLastT = now
        // Accumulate with decay so only recent motion remains (early vertical drift doesn't hinder later horizontal motion)
        scAccX = scAccX * 0.7 + dx; scAccY = scAccY * 0.7 + dy
        let ax = abs(scAccX), ay = abs(scAccY)
        if max(ax, ay) >= 30 {
            // Horizontal is judged first (horizontal motion tends to be a clearer sign of intent than vertical)
            let wantH: Bool? = ax >= 1.2 * ay ? true : (ay >= 1.8 * ax ? false : nil)
            if let w = wantH {
                if scLockH == nil { scLockH = w }
                else if scLockH != w {
                    // Switch axes when the opposite direction to the lock becomes overwhelming
                    let cur = scLockH == true ? ax : ay
                    let oth = scLockH == true ? ay : ax
                    if oth >= 2.5 * cur { scLockH = w }
                }
            }
        }
        switch scLockH {
        case .some(true): return (0, dx)
        case .some(false): return (dy, 0)
        case .none: return (dy, dx)
        }
    }

    /// Whether a swipe during sharing may be sent to the peer (decided by the peer's app)
    func swipeAllowedRemotely(_ action: SwipeAction) -> Bool {
        guard let bid = remoteAppID, remoteAppPeer == awayTo else { return true }
        if bid == "com.apple.finder" { return true }
        if Self.browserIDs.contains(bid) { return action == .back || action == .forward }
        return false
    }

    /// We are the originator and the cursor is on the peer's side
    var sessionActiveAway: Bool { sending && awayTo != nil }

    /// Whether we have any role in the sharing session (originator, holder, relay)
    var anySessionActive: Bool { sending || holding || forwardTo != nil }

    /// Send a swipe action to the peer as key input (with ⌘)
    func forwardActionKey(for action: SwipeAction) {
        guard let to = awayTo else { return }
        let code: Int64
        switch action {
        case .back: code = 33
        case .forward: code = 30
        case .parent: code = 126
        case .open: code = 31
        }
        let cmd = Int64(CGEventFlags.maskCommand.rawValue)
        LinkNet.sendFast("fl \(to) 55 \(cmd)")
        LinkNet.sendFast("kd \(to) \(code) \(cmd)")
        LinkNet.sendFast("ku \(to) \(code) \(cmd)")
        LinkNet.sendFast("fl \(to) 55 0")
    }

    /// When within 56px of an edge, show the destination in that direction with a border (originator, cursor local)
    private func updateGlowAtHome(_ loc: CGPoint) {
        if soloMode { EdgeGlow.shared.hide(); return }
        let b = allBounds
        let spots: [(PartnerDir, Double, Double)] = [
            (.right, Double(b.maxX) - Double(loc.x), (Double(loc.y) - Double(b.minY)) / Double(b.height)),
            (.left, Double(loc.x) - Double(b.minX), (Double(loc.y) - Double(b.minY)) / Double(b.height)),
            (.down, Double(b.maxY) - Double(loc.y), (Double(loc.x) - Double(b.minX)) / Double(b.width)),
            (.up, Double(loc.y) - Double(b.minY), (Double(loc.x) - Double(b.minX)) / Double(b.width)),
        ]
        // When approaching any destination (an edge with a link), light up all destinations
        let near = spots.contains { (dir, dist, _) in dist <= 56 && links.contains { $0.dir == dir } }
        if near && !links.isEmpty {
            EdgeGlow.shared.show(segments: links.map { (dir: $0.dir, link: $0) })
        } else {
            EdgeGlow.shared.hide()
        }
    }

    /// While holding: show the border based on the virtual cursor's proximity to the edge
    private func updateGlowHolding() {
        let b = allBounds
        let spots: [(PartnerDir, Double, Double)] = [
            (.right, Double(b.maxX) - vx, (vy - Double(b.minY)) / Double(b.height)),
            (.left, vx - Double(b.minX), (vy - Double(b.minY)) / Double(b.height)),
            (.down, Double(b.maxY) - vy, (vx - Double(b.minX)) / Double(b.width)),
            (.up, vy - Double(b.minY), (vx - Double(b.minX)) / Double(b.width)),
        ]
        // When approaching any destination (an edge with a link), light up all destinations
        let near = spots.contains { (dir, dist, _) in dist <= 56 && links.contains { $0.dir == dir } }
        if near && !links.isEmpty {
            EdgeGlow.shared.show(segments: links.map { (dir: $0.dir, link: $0) })
        } else {
            EdgeGlow.shared.hide()
        }
    }

    /// If touching an edge, hand off to the peer. Returns true if handed off
    /// When an edge push amount is set, we stay pinned to the edge and push outward;
    /// don't hand off until the total reaches that amount (also prevents jitter at the edge)
    private func checkEdges(_ event: CGEvent) -> Bool {
        if soloMode { return false }
        let b = allBounds
        let loc = event.location
        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        let push = Double(Self.pushPx)
        let checks: [(PartnerDir, Bool, Double, Double)] = [
            (.right, loc.x >= b.maxX - 1, Double((loc.y - b.minY) / b.height), dx),
            (.left, loc.x <= b.minX, Double((loc.y - b.minY) / b.height), -dx),
            (.down, loc.y >= b.maxY - 1, Double((loc.x - b.minX) / b.width), dy),
            (.up, loc.y <= b.minY, Double((loc.x - b.minX) / b.width), -dy),
        ]
        for (dir, hit, ratio, outward) in checks {
            if !hit { edgePush[dir] = 0; continue }
            guard let lk = link(dir: dir, at: ratio) else { continue }
            if push > 0 {
                edgePush[dir, default: 0] += max(0, outward)
                if edgePush[dir, default: 0] < push { continue }
            }
            // Normalize the handoff position to a "fraction within the shared edge" (so positions line up even with offset layouts)
            let seg = lk.end > lk.start ? min(1, max(0, (ratio - lk.start) / (lk.end - lk.start))) : 0.5
            sending = true
            awayTo = lk.id
            if remoteAppPeer != lk.id { remoteAppID = nil; remoteAppPeer = nil }
            edgePush.removeAll()
            multAccX = 0; multAccY = 0
            for _ in 0..<3 { LinkNet.sendFast("enter \(lk.id) \(seg) \(dir.rawValue)") }
            hideCursor()
            startPinning(at: loc)
            EdgeGlow.shared.hide()
            status("Cursor sharing: handed to \(peerName(lk.id))")
            return true
        }
        return false
    }

    /// Convert the originator's physical input into signals
    private func forwardPhysical(type: CGEventType, event: CGEvent, to: String) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            let mult = Self.moveMult
            if mult == 1 {
                if dx != 0 || dy != 0 { LinkNet.sendFast("mv \(to) \(dx) \(dy)") }
            } else {
                // Apply the multiplier and carry over the remainder (so slow movement isn't lost)
                multAccX += Double(dx) * mult
                multAccY += Double(dy) * mult
                let sx = Int(multAccX.rounded())
                let sy = Int(multAccY.rounded())
                multAccX -= Double(sx)
                multAccY -= Double(sy)
                if sx != 0 || sy != 0 { LinkNet.sendFast("mv \(to) \(sx) \(sy)") }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            LinkNet.sendFast("dn \(to) \(event.getIntegerValueField(.mouseEventButtonNumber))")
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            LinkNet.sendFast("up \(to) \(event.getIntegerValueField(.mouseEventButtonNumber))")
        case .scrollWheel:
            // During a browser horizontal-swipe gesture, don't send that scroll itself to the peer
            // (it would run wild as horizontal scrolling there, and even the rebound after lifting fingers would reach it)
            if scrollSuppressed { return }
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let (sdy, sdx) = axisLockedScroll(dy: dy, dx: dx)
            if sdx != 0 || sdy != 0 { LinkNet.sendFast("sc \(to) \(Int(sdy)) \(Int(sdx))") }
        case .keyDown:
            LinkNet.sendFast("kd \(to) \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue)")
        case .keyUp:
            LinkNet.sendFast("ku \(to) \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue)")
        case .flagsChanged:
            LinkNet.sendFast("fl \(to) \(event.getIntegerValueField(.keyboardEventKeycode)) \(event.flags.rawValue)")
        default:
            break
        }
    }

    // MARK: Receiving side (called from LinkNet; the first element of args is the destination ID)

    func receive(_ kind: String, args: [String], from: String) {
        guard enabled, let to = args.first, to == LinkNet.machineID else { return }
        let rest = Array(args.dropFirst())
        switch kind {
        case "enter":
            guard rest.count >= 1 else { return }
            let seg = Double(rest[0]) ?? 0.5
            // If the sender's exit direction is attached, remember the opposite side as the neighbor (auto-learning for setups without assignments)
            if rest.count >= 2, let exitDir = PartnerDir(rawValue: rest[1]) {
                learnLink(dir: exitDir.opposite, id: from)
            }
            if sending, awayTo != nil {
                // Went all the way around the ring back to the originator (us). Close the session and send a reset
                // to everyone so the relays' states are aligned
                sending = false
                awayTo = nil
                showCursor()
                stopPinning()
                if let d = dir(ofPeer: from) {
                    let r = entryRatio(forPeer: from, seg: seg)
                    let b = allBounds
                    let pt: CGPoint
                    switch d {
                    case .right: pt = CGPoint(x: Double(b.maxX) - 1, y: Double(b.minY) + r * Double(b.height))
                    case .left: pt = CGPoint(x: Double(b.minX), y: Double(b.minY) + r * Double(b.height))
                    case .down: pt = CGPoint(x: Double(b.minX) + r * Double(b.width), y: Double(b.maxY) - 1)
                    case .up: pt = CGPoint(x: Double(b.minX) + r * Double(b.width), y: Double(b.minY))
                    }
                    CGWarpMouseCursorPosition(pt)
                    CGAssociateMouseAndMouseCursorPosition(1)
                }
                LinkNet.sendReset()
                status("Cursor sharing: came back around")
                sendAtSelf()
                return
            }
            if soloMode {
                // Solo mode: don't accept it; send it straight back (the sender handles it as "returned to hand")
                LinkNet.sendFast("leave \(from) \(seg)")
                status("Solo mode: sent back cursor from \(peerName(from))")
                return
            }
            // Even as the originator, we can accept it if the cursor has returned locally (the session is yielded to the peer).
            // Rejecting here would cause an asymmetric jam where it can never be returned to a side we once sent to
            guard awayTo == nil, !holding, forwardTo == nil else { return }
            sending = false
            holding = true
            cameFrom = from
            sendAtSelf()
            reportFrontApp()
            if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)) }
            warp()
            status("Cursor sharing: received from \(peerName(from))")
        case "leave":
            guard rest.count >= 1 else { return }
            let seg = Double(rest[0]) ?? 0.5
            if awayTo == from {
                // The cursor returned to the originator (the session itself continues)
                awayTo = nil
                showCursor()
                stopPinning()
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)); warp() }
                status("Cursor sharing: back in hand")
                sendAtSelf()
            } else if forwardTo == from {
                // Returned from the peer we were relaying to → we become the holder (cameFrom stays the original peer)
                forwardTo = nil
                holding = true
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)); warp() }
                status("Cursor sharing: came back")
                sendAtSelf()
                reportFrontApp()
            }
        case "assign":
            // Layout assignment: replace the whole link table
            var newLinks: [PeerLink] = []
            for tok in rest {
                if tok.hasPrefix("c:") {
                    let kv = tok.dropFirst(2).split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { setMachineColorHex(String(kv[0]), String(kv[1])) }
                    continue
                }
                let kv = tok.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let d = PartnerDir(rawValue: String(kv[0])),
                      let lk = Self.parseLink(dir: d, spec: String(kv[1])) else { continue }
                newLinks.append(lk)
            }
            setLinks(newLinks)
            status("Layout: received assignment")
        case "at":
            if let holder = rest.first { cursorAtID = holder }
        case "app":
            if let bid = rest.first { remoteAppID = bid; remoteAppPeer = from }
        case "mother":
            UserDefaults.standard.set(from, forKey: "mothershipID")
            status("Host is now \(peerName(from))")
        case "swopen":
            SwitchSync.shared.openLocal()
        case "swdone":
            SwitchSync.shared.receiveDone()
        case "srch":
            SearchSync.shared.receiveOpen()
        case "sqry":
            if let b64 = rest.first { SearchSync.shared.receiveQuery(b64) }
        case "skey":
            if let k = rest.first { SearchSync.shared.receiveKey(k) }
        case "sdone":
            SearchSync.shared.receiveDone()
        case "identify":
            IdentifyGlow.shared.showSelf()
        case "threq":
            ThumbShare.shared.handleRequest(from: from)
        case "thimg":
            if rest.count >= 4, let idx = Int(rest[1]), let total = Int(rest[2]) {
                ThumbShare.shared.handleChunk(from: from, tid: rest[0], idx: idx, total: total, chunk: rest[3])
            }
        case "mv", "dn", "up", "sc", "kd", "ku", "fl":
            if (kind == "kd" || kind == "ku" || kind == "fl"), SearchSync.shared.receiving, !holding, forwardTo == nil {
                // Search sync: keystrokes that arrive while a search is open are reproduced as input to the search
                SearchSync.shared.applyRemoteKey(kind: kind, args: rest)
            } else if (kind == "kd" || kind == "ku" || kind == "fl"), SearchSync.shared.receiving {
                if kind == "kd" { NetLog.shared.log("Search sync: can't apply keystroke during a session") }
            } else if holding {
                apply(kind, args: rest)
            } else if let fwd = forwardTo {
                // Relay: rewrite the destination to the next peer and send it on as-is
                LinkNet.sendFast("\(kind) \(fwd) " + rest.joined(separator: " "))
            }
        default:
            break
        }
    }

    /// Tell all machines the cursor's current location (when we become the holder)
    private func sendAtSelf() {
        cursorAtID = LinkNet.machineID
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("at \(pid) \(LinkNet.machineID)")
        }
    }

    /// Place the virtual cursor at the edge position
    private func positionAtEdge(_ dir: PartnerDir, ratio: Double) {
        let b = allBounds
        switch dir {
        case .right: vx = Double(b.maxX) - 1; vy = Double(b.minY) + ratio * Double(b.height)
        case .left: vx = Double(b.minX); vy = Double(b.minY) + ratio * Double(b.height)
        case .down: vy = Double(b.maxY) - 1; vx = Double(b.minX) + ratio * Double(b.width)
        case .up: vy = Double(b.minY); vx = Double(b.minX) + ratio * Double(b.width)
        }
    }

    /// Handoff/return when crossing an edge. Returns true if performed
    private func cross(_ dir: PartnerDir, ratio: Double) -> Bool {
        guard let lk = link(dir: dir, at: ratio) else { return false }
        let seg = lk.end > lk.start ? min(1, max(0, (ratio - lk.start) / (lk.end - lk.start))) : 0.5
        let next = lk.id
        if next == cameFrom {
            LinkNet.sendFast("leave \(next) \(seg)")
            holding = false
            cameFrom = nil
            status("Cursor sharing: returned to hand")
        } else {
            LinkNet.sendFast("enter \(next) \(seg) \(dir.rawValue)")
            forwardTo = next
            holding = false
            status("Cursor sharing: handed to \(peerName(next))")
        }
        EdgeGlow.shared.hide()
        return true
    }

    private func apply(_ kind: String, args: [String]) {
        let b = allBounds
        switch kind {
        case "mv":
            guard args.count == 2, let dx = Double(args[0]), let dy = Double(args[1]) else { return }
            vx += dx
            vy += dy
            let ry = (vy - Double(b.minY)) / Double(b.height)
            let rx = (vx - Double(b.minX)) / Double(b.width)
            let push = Double(Self.pushPx)
            if push <= 0 {
                if vx >= Double(b.maxX), cross(.right, ratio: ry) { return }
                if vx < Double(b.minX), cross(.left, ratio: ry) { return }
                if vy >= Double(b.maxY), cross(.down, ratio: rx) { return }
                if vy < Double(b.minY), cross(.up, ratio: rx) { return }
            } else {
                // Hand off once the amount pushed while pinned at the edge reaches the set value
                if vx >= Double(b.maxX) {
                    holdPush[.right, default: 0] += vx - (Double(b.maxX) - 1)
                    vx = Double(b.maxX) - 1
                    if holdPush[.right, default: 0] >= push { holdPush.removeAll(); if cross(.right, ratio: ry) { return } }
                } else { holdPush[.right] = 0 }
                if vx < Double(b.minX) {
                    holdPush[.left, default: 0] += Double(b.minX) - vx
                    vx = Double(b.minX)
                    if holdPush[.left, default: 0] >= push { holdPush.removeAll(); if cross(.left, ratio: ry) { return } }
                } else { holdPush[.left] = 0 }
                if vy >= Double(b.maxY) {
                    holdPush[.down, default: 0] += vy - (Double(b.maxY) - 1)
                    vy = Double(b.maxY) - 1
                    if holdPush[.down, default: 0] >= push { holdPush.removeAll(); if cross(.down, ratio: rx) { return } }
                } else { holdPush[.down] = 0 }
                if vy < Double(b.minY) {
                    holdPush[.up, default: 0] += Double(b.minY) - vy
                    vy = Double(b.minY)
                    if holdPush[.up, default: 0] >= push { holdPush.removeAll(); if cross(.up, ratio: rx) { return } }
                } else { holdPush[.up] = 0 }
            }
            vx = min(max(vx, Double(b.minX)), Double(b.maxX) - 1)
            vy = min(max(vy, Double(b.minY)), Double(b.maxY) - 1)
            updateGlowHolding()
            postMoveThrottled()
        case "dn", "up":
            guard let n = args.first.flatMap({ Int($0) }) else { return }
            if kind == "dn" { downButtons.insert(n) } else { downButtons.remove(n) }
            postMouse(down: kind == "dn", button: n)
        case "sc":
            guard args.count == 2, let dy = Int32(args[0]), let dx = Int32(args[1]) else { return }
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                e.location = CGPoint(x: vx, y: vy)
                e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                e.post(tap: .cghidEventTap)
            }
        case "kd", "ku", "fl":
            guard args.count == 2, let code = UInt16(args[0]), let flagsRaw = UInt64(args[1]) else { return }
            if kind == "fl" || code == 126 || code == 99 {
                NetLog.shared.log("Key applied: \(kind) code=\(code) flags=\(flagsRaw)")
            }
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: kind != "ku") {
                e.flags = CGEventFlags(rawValue: flagsRaw)
                if kind == "fl" { e.type = .flagsChanged }
                e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                e.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    private func warp() {
        CGWarpMouseCursorPosition(CGPoint(x: vx, y: vy))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private var downButtons = Set<Int>()

    /// The receiving side's movement is emitted as a "real mouse-move event".
    /// A warp alone doesn't trigger mechanisms that watch move events, such as Dock auto-show or hover
    private func postMove() {
        let type: CGEventType
        if downButtons.contains(1) { type = .rightMouseDragged }
        else if downButtons.contains(2) { type = .otherMouseDragged }
        else if downButtons.contains(0) { type = .leftMouseDragged }
        else { type = .mouseMoved }
        if let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: vx, y: vy), mouseButton: .left) {
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    private var lastMovePost = Date.distantPast
    private var movePostScheduled = false

    private func postMoveThrottled() {
        if Date().timeIntervalSince(lastMovePost) >= 0.008 {
            lastMovePost = Date()
            postMove()
            return
        }
        if !movePostScheduled {
            movePostScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                guard let self = self else { return }
                self.movePostScheduled = false
                if self.holding {
                    self.lastMovePost = Date()
                    self.postMove()
                }
            }
        }
    }

    private var lastWarp = Date.distantPast
    private var warpScheduled = false

    /// The receiving side's cursor movement is throttled to about once per 8 ms (warping on every signal would slow things down)
    private func warpThrottled() {
        if Date().timeIntervalSince(lastWarp) >= 0.008 {
            lastWarp = Date()
            warp()
            return
        }
        if !warpScheduled {
            warpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                guard let self = self else { return }
                self.warpScheduled = false
                if self.holding {
                    self.lastWarp = Date()
                    self.warp()
                }
            }
        }
    }

    private func postMouse(down: Bool, button: Int) {
        let downType: CGEventType, upType: CGEventType, btn: CGMouseButton
        switch button {
        case 1: downType = .rightMouseDown; upType = .rightMouseUp; btn = .right
        case 2: downType = .otherMouseDown; upType = .otherMouseUp; btn = .center
        default: downType = .leftMouseDown; upType = .leftMouseUp; btn = .left
        }
        if let e = CGEvent(mouseEventSource: nil, mouseType: down ? downType : upType,
                           mouseCursorPosition: CGPoint(x: vx, y: vy), mouseButton: btn) {
            e.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    private func status(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(s) }
    }
}

// MARK: - Loading MultitouchSupport

final class Multitouch {
    typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
    typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private static var retainedList: CFMutableArray?

    /// Returns the number of devices connected (0 = failure)
    static func start() -> Int {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(handle, "MTDeviceCreateList"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let listPtr = unsafeBitCast(createSym, to: CreateListFn.self)() else { return 0 }
        let register = unsafeBitCast(regSym, to: RegisterFn.self)
        let start = unsafeBitCast(startSym, to: StartFn.self)
        let list = Unmanaged<CFMutableArray>.fromOpaque(listPtr).takeRetainedValue()
        retainedList = list
        let n = CFArrayGetCount(list)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let dev = CFArrayGetValueAtIndex(list, i)
            register(UnsafeMutableRawPointer(mutating: dev), mtCallback)
            start(UnsafeMutableRawPointer(mutating: dev), 0)
        }
        return n
    }
}



// MARK: - Machine color and edge border display

/// Builds an NSColor from "#RRGGBB"
func colorFromHex(_ hex: String) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return .systemBlue }
    return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func hexFromColor(_ c: NSColor) -> String {
    let rgb = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
}

/// Machine color: the configured one if set, otherwise a color derived stably from the ID
func machineColorHex(of id: String) -> String {
    let map = UserDefaults.standard.dictionary(forKey: "machineColors") as? [String: String] ?? [:]
    if let hex = map[id] { return hex }
    var h: UInt64 = 5381
    for u in id.unicodeScalars { h = h &* 33 &+ UInt64(u.value) }
    let hue = Double(h % 360) / 360.0
    return hexFromColor(NSColor(hue: CGFloat(hue), saturation: 0.65, brightness: 0.95, alpha: 1))
}

func setMachineColorHex(_ id: String, _ hex: String) {
    var map = UserDefaults.standard.dictionary(forKey: "machineColors") as? [String: String] ?? [:]
    map[id] = hex
    UserDefaults.standard.set(map, forKey: "machineColors")
}

/// Display that glows the screen outline in the destination machine's color when nearing an edge.
/// The destination segment glows strongly, so color breaks mark the boundaries between neighbors
final class EdgeGlow {
    static let shared = EdgeGlow()
    private var window: NSWindow?
    private var view: EdgeGlowView?
    private var timer: Timer?
    fileprivate var alpha = 0.0
    private var targetAlpha = 0.0
    fileprivate var segs: [(dir: PartnerDir, color: NSColor, start: Double, end: Double)] = []

    /// Glow all traversable segments at the same time
    func show(segments: [(dir: PartnerDir, link: PeerLink)]) {
        let mapped = segments.map { (dir: $0.dir, color: colorFromHex(machineColorHex(of: $0.link.id)), start: $0.link.start, end: $0.link.end) }
        onMain { [weak self] in
            guard let self = self else { return }
            self.ensureWindow()
            self.segs = mapped
            self.targetAlpha = 1
            self.startTimer()
        }
    }

    func hide() {
        onMain { [weak self] in
            self?.targetAlpha = 0
            self?.startTimer()
        }
    }

    /// Always run via the main queue. The local path is called from the event tap (main thread),
    /// so running immediately would differ in execution context from the holding path (receive queue → main queue)
    /// and the display may become unstable, so the paths are aligned
    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    private func ensureWindow() {
        if window != nil { return }
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let v = EdgeGlowView(frame: NSRect(origin: .zero, size: union.size))
        v.owner = self
        let w = NSWindow(contentRect: union, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window = w
        view = v
    }

    private func startTimer() {
        if timer != nil { return }
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let diff = self.targetAlpha - self.alpha
            self.alpha = abs(diff) < 0.04 ? self.targetAlpha : self.alpha + diff * 0.35
            if self.alpha <= 0.01 && self.targetAlpha == 0 {
                self.window?.orderOut(nil)
                self.timer?.invalidate()
                self.timer = nil
                return
            }
            self.window?.orderFrontRegardless()
            self.view?.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

final class EdgeGlowView: NSView {
    weak var owner: EdgeGlow?

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner, o.alpha > 0.01, !o.segs.isEmpty else { return }
        let a = CGFloat(o.alpha)
        // Glow only the traversable segments, each in its destination's color (never the whole outline in the nearest entry's color)
        // Make the destination segment strong (blurred with a shadow). Leave margins at both ends of each segment so neighboring colors don't mix
        let w = Double(bounds.width), h = Double(bounds.height)
        let margin = 10.0
        for si in o.segs {
            let seg = NSBezierPath()
            switch si.dir {
            case .right, .left:
                let x = si.dir == .right ? w - 4 : 4
                var y1 = h * (1 - si.start), y2 = h * (1 - si.end)
                if y1 > y2 { swap(&y1, &y2) }
                if y2 - y1 > margin * 2 + 4 { y1 += margin; y2 -= margin }
                seg.move(to: NSPoint(x: x, y: y1))
                seg.line(to: NSPoint(x: x, y: y2))
            case .down, .up:
                let y = si.dir == .down ? 4.0 : h - 4
                var x1 = w * si.start, x2 = w * si.end
                if x2 - x1 > margin * 2 + 4 { x1 += margin; x2 -= margin }
                seg.move(to: NSPoint(x: x1, y: y))
                seg.line(to: NSPoint(x: x2, y: y))
            }
            let shadow = NSShadow()
            shadow.shadowColor = si.color.withAlphaComponent(0.9 * a)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = .zero
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            si.color.withAlphaComponent(0.95 * a).setStroke()
            seg.lineWidth = 5
            seg.lineCapStyle = .round
            seg.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

// MARK: - Layout arrangement

/// Handles the arrangement (machine ID → origin), the neighbor links derived from it, and sending assignments
enum LayoutStore {
    static func loadPos() -> [String: (x: Double, y: Double)] {
        if let d = UserDefaults.standard.dictionary(forKey: "layoutPos") as? [String: String], !d.isEmpty {
            var out: [String: (x: Double, y: Double)] = [:]
            for (k, v) in d {
                let p = v.split(separator: ",")
                if p.count == 2, let x = Double(p[0]), let y = Double(p[1]) { out[k] = (x, y) }
            }
            if !out.isEmpty { return out }
        }
        return synthesizedPos()
    }

    /// For first run: build the arrangement from existing links (our neighbors)
    static func synthesizedPos() -> [String: (x: Double, y: Double)] {
        let links = CursorShare.shared.links
        guard !links.isEmpty else { return [:] }
        var pos: [String: (x: Double, y: Double)] = [LinkNet.machineID: (0, 0)]
        let my = size(of: LinkNet.machineID)
        for lk in links where pos[lk.id] == nil {
            let s = size(of: lk.id)
            switch lk.dir {
            case .right: pos[lk.id] = (my.w, 0)
            case .left: pos[lk.id] = (-s.w, 0)
            case .down: pos[lk.id] = (0, my.h)
            case .up: pos[lk.id] = (0, -s.h)
            }
        }
        return pos
    }

    static func savePos(_ pos: [String: (x: Double, y: Double)]) {
        var d: [String: String] = [:]
        for (k, v) in pos { d[k] = "\(Int(v.x.rounded())),\(Int(v.y.rounded()))" }
        UserDefaults.standard.set(d, forKey: "layoutPos")
    }

    static func size(of id: String) -> (w: Double, h: Double) {
        if id == LinkNet.machineID {
            let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
            if union.width > 0 { return (Double(union.width), Double(union.height)) }
            return (1920, 1080)
        }
        if let s = LinkNet.peerSizes[id] { return (Double(s.w), Double(s.h)) }
        return (1920, 1080)
    }

    static func rects(pos: [String: (x: Double, y: Double)]) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for (id, p) in pos {
            let s = size(of: id)
            out[id] = CGRect(x: p.x, y: p.y, width: s.w, height: s.h)
        }
        return out
    }

    static func name(of id: String) -> String {
        if id == LinkNet.machineID { return Host.current().localizedName ?? "Mac" }
        if let n = LinkNet.peers[id]?.name { return n }
        let cache = UserDefaults.standard.dictionary(forKey: "layoutNames") as? [String: String] ?? [:]
        return cache[id] ?? id
    }

    /// Derive the link table for all machines from the arrangement (a machine is a neighbor if edges touch and overlap by 30px or more)
    static func derive(rects: [String: CGRect]) -> [String: [PeerLink]] {
        var result: [String: [PeerLink]] = [:]
        let tol: CGFloat = 24
        for (id, r) in rects {
            var mine: [PeerLink] = []
            for (oid, o) in rects where oid != id {
                if abs(o.minX - r.maxX) <= tol {
                    let lo = max(r.minY, o.minY), hi = min(r.maxY, o.maxY)
                    if hi - lo >= 30 { mine.append(PeerLink(dir: .right, id: oid, start: (lo - r.minY) / r.height, end: (hi - r.minY) / r.height)) }
                }
                if abs(o.maxX - r.minX) <= tol {
                    let lo = max(r.minY, o.minY), hi = min(r.maxY, o.maxY)
                    if hi - lo >= 30 { mine.append(PeerLink(dir: .left, id: oid, start: (lo - r.minY) / r.height, end: (hi - r.minY) / r.height)) }
                }
                if abs(o.minY - r.maxY) <= tol {
                    let lo = max(r.minX, o.minX), hi = min(r.maxX, o.maxX)
                    if hi - lo >= 30 { mine.append(PeerLink(dir: .down, id: oid, start: (lo - r.minX) / r.width, end: (hi - r.minX) / r.width)) }
                }
                if abs(o.maxY - r.minY) <= tol {
                    let lo = max(r.minX, o.minX), hi = min(r.maxX, o.maxX)
                    if hi - lo >= 30 { mine.append(PeerLink(dir: .up, id: oid, start: (lo - r.minX) / r.width, end: (hi - r.minX) / r.width)) }
                }
            }
            result[id] = mine
        }
        // Junction gap: at corners where several machines meet (T or cross junctions), the point is shared,
        // so shift the link ends slightly to both sides (2% of our edge) to create an "uncrossable band".
        // This prevents the cursor from getting lost when corners are contested
        let gapR = 0.02
        struct EndRef { let owner: String; let idx: Int; let isHi: Bool; let coord: Double; let line: Double }
        var ends: [EndRef] = []
        for (id, links) in result {
            guard let r = rects[id] else { continue }
            for (i, lk) in links.enumerated() {
                switch lk.dir {
                case .right, .left:
                    let line = Double(lk.dir == .right ? r.maxX : r.minX)
                    ends.append(EndRef(owner: id, idx: i, isHi: false, coord: Double(r.minY) + lk.start * Double(r.height), line: line))
                    ends.append(EndRef(owner: id, idx: i, isHi: true, coord: Double(r.minY) + lk.end * Double(r.height), line: line))
                case .down, .up:
                    let line = Double(lk.dir == .down ? r.maxY : r.minY)
                    ends.append(EndRef(owner: id, idx: i, isHi: false, coord: Double(r.minX) + lk.start * Double(r.width), line: line))
                    ends.append(EndRef(owner: id, idx: i, isHi: true, coord: Double(r.minX) + lk.end * Double(r.width), line: line))
                }
            }
        }
        var marked = Set<String>()
        for a in ends {
            for b in ends where b.owner != a.owner && b.isHi != a.isHi {
                if abs(a.coord - b.coord) <= 24 && abs(a.line - b.line) <= 50 {
                    marked.insert("\(a.owner)|\(a.idx)|\(a.isHi ? "h" : "l")")
                }
            }
        }
        if !marked.isEmpty {
            for e in ends where marked.contains("\(e.owner)|\(e.idx)|\(e.isHi ? "h" : "l")") {
                guard let r = rects[e.owner], var links = result[e.owner], e.idx < links.count else { continue }
                var lk = links[e.idx]
                let horiz = lk.dir == .up || lk.dir == .down
                let len = Double(horiz ? r.width : r.height)
                let origin = Double(horiz ? r.minX : r.minY)
                let newCoord = e.isHi ? e.coord - gapR * len : e.coord + gapR * len
                let ratio = (newCoord - origin) / len
                if e.isHi { lk.end = min(lk.end, ratio) } else { lk.start = max(lk.start, ratio) }
                links[e.idx] = lk
                result[e.owner] = links
            }
            for id in Array(result.keys) {
                result[id] = (result[id] ?? []).filter { $0.end - $0.start >= 0.04 }
            }
        }
        return result
    }

    /// Save the arrangement, apply it to our links, and send assignments to all other machines
    static func apply(pos: [String: (x: Double, y: Double)]) {
        savePos(pos)
        // When a mothership is set, only the mothership distributes (prevents accidental overwrite by a stale arrangement)
        if let mid = UserDefaults.standard.string(forKey: "mothershipID"), mid != LinkNet.machineID { return }
        let all = derive(rects: rects(pos: pos))
        CursorShare.shared.setLinks(all[LinkNet.machineID] ?? [])
        for (id, lks) in all where id != LinkNet.machineID { sendAssign(to: id, links: lks) }
        let members = Set(UserDefaults.standard.stringArray(forKey: "layoutMembers") ?? [])
        for id in members where pos[id] == nil && id != LinkNet.machineID { sendAssign(to: id, links: []) }
        UserDefaults.standard.set(Array(pos.keys), forKey: "layoutMembers")
    }

    static func sendAssign(to id: String, links: [PeerLink]) {
        var tokens = links.isEmpty ? ["none"] : links.map { "\($0.dir.rawValue)=\($0.spec)" }
        // Distribute the color table as well (used for the edge border display)
        for cid in loadPos().keys {
            tokens.append("c:\(cid)=\(machineColorHex(of: cid))")
        }
        LinkNet.sendFast("assign \(id) " + tokens.joined(separator: " "))
        lastAssign[id] = Date()
    }

    private static var lastAssign: [String: Date] = [:]

    /// Called on every hello. Resends the remembered assignment to a peer that reappears after a while
    static func noteHello(id: String, prevSeen: Date?) {
        let pos = loadPos()
        guard pos[id] != nil else { return }
        let now = Date()
        if let prev = prevSeen, now.timeIntervalSince(prev) < 25 { return }
        if let last = lastAssign[id], now.timeIntervalSince(last) < 60 { return }
        // When a mothership is set, only the mothership resends. If we are the mothership, also announce that
        if let mid = UserDefaults.standard.string(forKey: "mothershipID"), mid != LinkNet.machineID { return }
        if UserDefaults.standard.string(forKey: "mothershipID") == LinkNet.machineID {
            LinkNet.sendFast("mother \(id)")
        }
        let all = derive(rects: rects(pos: pos))
        sendAssign(to: id, links: all[id] ?? [])
    }
}

/// Canvas for the layout editor. Drag tiles to arrange them; machines whose edges touch become neighbors.
/// With snapping on, our edges/center snap to other tiles' edges/center lines and guide lines are shown
final class LayoutCanvasView: NSView {
    private var pos: [String: (x: Double, y: Double)] = LayoutStore.loadPos()
    var snapEnabled = UserDefaults.standard.object(forKey: "layoutSnap") as? Bool ?? true

    private var dragID: String?
    private var dragFromTray = false
    private var grabDX = 0.0, grabDY = 0.0
    private var dragRect = CGRect.zero
    private var guideX: [Double] = []
    private var guideY: [Double] = []
    private var curScene = CGRect.zero
    private var curK: CGFloat = 0.15
    private var timer: Timer?
    private var swatches: [String: NSRect] = [:]

    private var trayHeight: CGFloat { 96 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
    }

    // MARK: Coordinate conversion (layout coordinates have y down, the view has y up)
    private func freezeTransform() {
        let rs = Array(LayoutStore.rects(pos: pos).values)
        var scene: CGRect
        if rs.isEmpty {
            let s = LayoutStore.size(of: LinkNet.machineID)
            scene = CGRect(x: 0, y: 0, width: s.w, height: s.h)
        } else {
            scene = rs.dropFirst().reduce(rs[0]) { $0.union($1) }
        }
        scene = scene.insetBy(dx: -160, dy: -160)
        curScene = scene
        let availW = Double(bounds.width) - 24
        let availH = Double(bounds.height - trayHeight) - 24
        curK = CGFloat(min(availW / Double(scene.width), availH / Double(scene.height)))
    }

    private func toView(_ r: CGRect) -> NSRect {
        let k = Double(curK)
        let x = 12 + (Double(r.minX) - Double(curScene.minX)) * k
        let topDist = (Double(r.minY) - Double(curScene.minY)) * k
        let y = Double(bounds.height) - 12 - topDist - Double(r.height) * k
        return NSRect(x: x, y: y, width: Double(r.width) * k, height: Double(r.height) * k)
    }

    private func toArrangement(_ p: NSPoint) -> (x: Double, y: Double) {
        let k = Double(curK)
        let x = Double(curScene.minX) + (Double(p.x) - 12) / k
        let y = Double(curScene.minY) + (Double(bounds.height) - 12 - Double(p.y)) / k
        return (x, y)
    }

    private func trayIDs() -> [String] {
        let now = Date()
        var ids: [String] = []
        for (id, info) in LinkNet.peers where now.timeIntervalSince(info.seen) < 120 && pos[id] == nil {
            ids.append(id)
        }
        return ids.sorted { LayoutStore.name(of: $0) < LayoutStore.name(of: $1) }
    }

    private func trayRect(index: Int, id: String) -> NSRect {
        let s = LayoutStore.size(of: id)
        let w = 132.0, h = 60.0
        let ratio = min(w / s.w, h / s.h)
        let tw = s.w * ratio, th = s.h * ratio
        let x = 16 + Double(index) * (w + 12) + (w - tw) / 2
        let y = 14 + (h - th) / 2
        return NSRect(x: x, y: y, width: tw, height: th)
    }

    // MARK: Changing colors
    private var colorTarget: String?

    private func pickColor(for id: String) {
        colorTarget = id
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPicked(_:)))
        panel.color = colorFromHex(machineColorHex(of: id))
        panel.isContinuous = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func colorPicked(_ sender: NSColorPanel) {
        guard let id = colorTarget else { return }
        setMachineColorHex(id, hexFromColor(sender.color))
        LayoutStore.apply(pos: LayoutStore.loadPos())
        needsDisplay = true
    }

    // MARK: Dragging
    override func mouseDown(with event: NSEvent) {
        freezeTransform()
        let p = convert(event.locationInWindow, from: nil)
        for (id, r) in swatches where r.contains(p) {
            pickColor(for: id)
            return
        }
        for (id, r) in LayoutStore.rects(pos: pos) {
            if toView(r).contains(p) {
                dragID = id
                dragFromTray = false
                let ap = toArrangement(p)
                grabDX = ap.x - Double(r.minX)
                grabDY = ap.y - Double(r.minY)
                dragRect = r
                needsDisplay = true
                return
            }
        }
        for (i, id) in trayIDs().enumerated() {
            if trayRect(index: i, id: id).contains(p) {
                dragID = id
                dragFromTray = true
                let s = LayoutStore.size(of: id)
                let ap = toArrangement(p)
                grabDX = s.w / 2
                grabDY = s.h / 2
                dragRect = CGRect(x: ap.x - grabDX, y: ap.y - grabDY, width: s.w, height: s.h)
                needsDisplay = true
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = dragID else { return }
        let p = convert(event.locationInWindow, from: nil)
        let ap = toArrangement(p)
        var nx = ap.x - grabDX
        var ny = ap.y - grabDY
        guideX = []
        guideY = []
        if snapEnabled {
            let w = Double(dragRect.width), h = Double(dragRect.height)
            let others = LayoutStore.rects(pos: pos).filter { $0.key != id }.map { $0.value }
            let threshold = 14.0 / Double(curK)
            var bestX: (val: Double, delta: Double, guide: Double)?
            var bestY: (val: Double, delta: Double, guide: Double)?
            for o in others {
                let ox = Double(o.minX), oMaxX = Double(o.maxX), oMidX = Double(o.midX)
                let oy = Double(o.minY), oMaxY = Double(o.maxY), oMidY = Double(o.midY)
                for (cand, guide) in [(ox - w, ox), (oMaxX, oMaxX), (ox, ox), (oMaxX - w, oMaxX), (oMidX - w / 2, oMidX), (oMidX, oMidX), (oMidX - w, oMidX), (ox - w / 2, ox), (oMaxX - w / 2, oMaxX)] {
                    let d = abs(cand - nx)
                    if d <= threshold && (bestX == nil || d < bestX!.delta) { bestX = (cand, d, guide) }
                }
                for (cand, guide) in [(oy - h, oy), (oMaxY, oMaxY), (oy, oy), (oMaxY - h, oMaxY), (oMidY - h / 2, oMidY), (oMidY, oMidY), (oMidY - h, oMidY), (oy - h / 2, oy), (oMaxY - h / 2, oMaxY)] {
                    let d = abs(cand - ny)
                    if d <= threshold && (bestY == nil || d < bestY!.delta) { bestY = (cand, d, guide) }
                }
            }
            if let b = bestX { nx = b.val; guideX = [b.guide] }
            if let b = bestY { ny = b.val; guideY = [b.guide] }
        }
        dragRect.origin = CGPoint(x: nx, y: ny)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let id = dragID else { return }
        let p = convert(event.locationInWindow, from: nil)
        if Double(p.y) < Double(trayHeight) {
            pos[id] = nil
        } else {
            pos[id] = (Double(dragRect.minX), Double(dragRect.minY))
        }
        dragID = nil
        dragFromTray = false
        guideX = []
        guideY = []
        LayoutStore.apply(pos: pos)
        needsDisplay = true
    }

    // MARK: Drawing
    override func draw(_ dirtyRect: NSRect) {
        if dragID == nil { freezeTransform() }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let tray = NSRect(x: 0, y: 0, width: bounds.width, height: trayHeight)
        NSColor.windowBackgroundColor.setFill()
        tray.fill()
        NSColor.separatorColor.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: 0, y: Double(trayHeight) - 0.5))
        sep.line(to: NSPoint(x: Double(bounds.width), y: Double(trayHeight) - 0.5))
        sep.lineWidth = 1
        sep.stroke()
        let label = "Unplaced (drag from here to place; drag back to the bar below to remove)"
        let lattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (label as NSString).draw(at: NSPoint(x: 16, y: Double(trayHeight) - 22), withAttributes: lattrs)

        // Snap guide lines
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        for gx in guideX {
            let v = toView(CGRect(x: gx, y: curScene.minY, width: 0, height: curScene.height))
            let path = NSBezierPath()
            path.move(to: NSPoint(x: v.minX, y: trayHeight))
            path.line(to: NSPoint(x: v.minX, y: bounds.height))
            path.lineWidth = 1
            path.stroke()
        }
        for gy in guideY {
            let v = toView(CGRect(x: curScene.minX, y: gy, width: curScene.width, height: 0))
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: v.maxY))
            path.line(to: NSPoint(x: bounds.width, y: v.maxY))
            path.lineWidth = 1
            path.stroke()
        }

        for (id, r) in LayoutStore.rects(pos: pos) where id != dragID {
            drawTile(id: id, viewRect: toView(r), dragging: false)
        }
        for (i, id) in trayIDs().enumerated() where id != dragID {
            drawTile(id: id, viewRect: trayRect(index: i, id: id), dragging: false)
        }
        if let id = dragID {
            drawTile(id: id, viewRect: toView(dragRect), dragging: true)
        }
    }

    private func drawTile(id: String, viewRect: NSRect, dragging: Bool) {
        let path = NSBezierPath(roundedRect: viewRect, xRadius: 8, yRadius: 8)
        let isSelf = id == LinkNet.machineID
        let online = isSelf || (LinkNet.peers[id].map { Date().timeIntervalSince($0.seen) < 120 } ?? false)
        (online ? NSColor.textBackgroundColor : NSColor.textBackgroundColor.withAlphaComponent(0.4)).setFill()
        path.fill()
        // If a screen thumbnail has arrived, show it in the tile (only if within 30 seconds)
        var freshThumb: NSImage? = nil
        if let th = ThumbShare.shared.images[id], Date().timeIntervalSince(th.at) < 30 {
            freshThumb = th.img
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            th.img.draw(in: viewRect, from: NSRect(origin: .zero, size: th.img.size), operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
        let mcol = colorFromHex(machineColorHex(of: id))
        mcol.setStroke()
        path.lineWidth = (isSelf ? 3 : 2.5) + (dragging ? 1.5 : 0)
        path.stroke()
        // Color chip at top right (click to change color)
        let chip = NSRect(x: viewRect.maxX - 21, y: viewRect.maxY - 21, width: 15, height: 15)
        let chipPath = NSBezierPath(ovalIn: chip)
        mcol.setFill()
        chipPath.fill()
        NSColor.white.setStroke()
        chipPath.lineWidth = 2
        chipPath.stroke()
        swatches[id] = chip
        let name = LayoutStore.name(of: id) + (isSelf ? " (this Mac)" : "")
        let s = LayoutStore.size(of: id)
        let sub = "\(Int(s.w))×\(Int(s.h))" + (online ? "" : " · not responding")
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let midY = Double(viewRect.midY)
        if freshThumb != nil {
            // Text is hard to read over a thumbnail, so lay a band underneath
            let band = NSRect(x: viewRect.minX + 4, y: CGFloat(midY - 21), width: viewRect.width - 8, height: 37)
            NSColor.textBackgroundColor.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: band, xRadius: 5, yRadius: 5).fill()
        }
        let nameRect = NSRect(x: viewRect.minX + 4, y: CGFloat(midY - 2), width: viewRect.width - 8, height: 16)
        (name as NSString).draw(in: nameRect, withAttributes: nameAttrs)
        let subRect = NSRect(x: viewRect.minX + 4, y: CGFloat(midY - 18), width: viewRect.width - 8, height: 13)
        (sub as NSString).draw(in: subRect, withAttributes: subAttrs)
    }
}

/// Screen identification: faintly glow the whole screen in our machine's color (for the layout editor's "Identify Screens")
final class IdentifyGlow {
    static let shared = IdentifyGlow()
    private var window: NSWindow?
    private var view: IdentifyGlowView?
    private var generation = 0

    func showSelf() {
        let c = colorFromHex(machineColorHex(of: LinkNet.machineID))
        let name = LayoutStore.name(of: LinkNet.machineID)
        if Thread.isMainThread { show(color: c, name: name) }
        else { DispatchQueue.main.async { [weak self] in self?.show(color: c, name: name) } }
    }

    private func show(color: NSColor, name: String) {
        generation += 1
        let gen = generation
        ensureWindow()
        view?.color = color
        view?.name = name
        view?.needsDisplay = true
        window?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self = self, self.generation == gen else { return }
            self.window?.orderOut(nil)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let v = IdentifyGlowView(frame: NSRect(origin: .zero, size: union.size))
        let w = NSWindow(contentRect: union, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window = w
        view = v
    }
}

final class IdentifyGlowView: NSView {
    var color: NSColor = .systemBlue
    var name: String = ""
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.30).setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let s = NSAttributedString(string: name, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// Layout editor window
// MARK: - Screen thumbnails

/// Sending/receiving used to show a reduced image of each machine's screen in the layout editor tiles.
/// The device with the editor open sends threq; the receiver captures its own screen
/// and returns the JPEG in small pieces (thimg). Latency doesn't matter (a few seconds is fine)
final class ThumbShare {
    static let shared = ThumbShare()
    private(set) var images: [String: (img: NSImage, at: Date)] = [:]
    private var assembly: [String: (tid: String, parts: [Int: String], total: Int)] = [:]
    private var lastCaptureAt = Date.distantPast
    private var capturing = false

    /// Received threq: capture our own screen and send it to the requester
    func handleRequest(from: String) {
        captureThrottled { data in
            guard let data = data else { return }
            let b64 = data.base64EncodedString()
            let tid = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            let total = (b64.count + 799) / 800
            for idx in 0..<total {
                let s = b64.index(b64.startIndex, offsetBy: idx * 800)
                let e = b64.index(s, offsetBy: min(800, b64.count - idx * 800))
                LinkNet.sendFast("thimg \(from) \(tid) \(idx) \(total) \(b64[s..<e])")
            }
        }
    }

    /// Our own thumbnail (for our own tile). Stored locally without sending
    func captureOwn() {
        captureThrottled { data in
            guard let data = data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { ThumbShare.shared.images[LinkNet.machineID] = (img, Date()) }
        }
    }

    private func captureThrottled(_ completion: @escaping (Data?) -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastCaptureAt) > 2, !capturing else { completion(nil); return }
        lastCaptureAt = now
        capturing = true
        captureScreen { [weak self] data in
            self?.capturing = false
            completion(data)
        }
    }

    /// Make our screen into a 320px-wide JPEG (fails without Screen Recording permission)
    private func captureScreen(completion: @escaping (Data?) -> Void) {
        guard #available(macOS 14.0, *) else { completion(nil); return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else { completion(nil); return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = 320
                cfg.height = max(1, 320 * display.height / max(1, display.width))
                cfg.showsCursor = false
                let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                let rep = NSBitmapImageRep(cgImage: cg)
                completion(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55]))
            } catch {
                NetLog.shared.log("Thumbnail capture failed: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    /// Received thimg: gather the pieces into one image (assembled on the main thread)
    func handleChunk(from: String, tid: String, idx: Int, total: Int, chunk: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var a = self.assembly[from] ?? (tid: tid, parts: [Int: String](), total: total)
            if a.tid != tid { a = (tid: tid, parts: [:], total: total) }
            a.parts[idx] = chunk
            a.total = total
            self.assembly[from] = a
            guard a.parts.count >= total else { return }
            let b64 = (0..<total).map { a.parts[$0] ?? "" }.joined()
            self.assembly[from] = nil
            guard let data = Data(base64Encoded: b64), let img = NSImage(data: data) else { return }
            self.images[from] = (img, Date())
        }
    }
}

final class LayoutWindowController: NSWindowController, NSWindowDelegate {
    private var canvas: LayoutCanvasView!

    convenience init() {
        self.init(window: nil)
        canvas = LayoutCanvasView(frame: NSRect(x: 0, y: 0, width: 680, height: 470))
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let snapBox = NSButton(checkboxWithTitle: "Snap (to edges and center lines)", target: self, action: #selector(toggleSnap(_:)))
        let idButton = NSButton(title: "Identify Screens", target: self, action: #selector(identifyScreens))
        idButton.bezelStyle = .rounded
        let motherButton = NSButton(title: "Make This Device the Mothership", target: self, action: #selector(becomeMothership))
        motherButton.bezelStyle = .rounded
        snapBox.state = canvas.snapEnabled ? .on : .off
        let hint = NSTextField(labelWithString: "Machines become neighbors when their edges touch. Use the circle at a tile's top right to change that machine's color")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        // Putting buttons and the description on one row can run out of width and make buttons disappear, so use two rows
        let bar = NSStackView(views: [snapBox, idButton, motherButton])
        bar.orientation = .horizontal
        bar.spacing = 16
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)
        let hintBar = NSStackView(views: [hint])
        hintBar.orientation = .horizontal
        hintBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        let root = NSStackView(views: [bar, hintBar, canvas])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 548), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = mothershipTitle()
        window.contentView = root
        window.minSize = NSSize(width: 480, height: 400)
        window.delegate = self
        self.window = window
    }

    private var thumbTimer: Timer?

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startThumbPolling()
    }

    func windowWillClose(_ notification: Notification) {
        thumbTimer?.invalidate()
        thumbTimer = nil
    }

    /// Collect each machine's screen thumbnail only while the editor is open
    private func startThumbPolling() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        requestThumbs()
        thumbTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.requestThumbs() }
        RunLoop.main.add(t, forMode: .common)
        thumbTimer = t
    }

    private func requestThumbs() {
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("threq \(pid)")
        }
        ThumbShare.shared.captureOwn()
        canvas.needsDisplay = true
    }

    @objc func toggleSnap(_ b: NSButton) {
        canvas.snapEnabled = b.state == .on
        UserDefaults.standard.set(canvas.snapEnabled, forKey: "layoutSnap")
    }

    /// Glow every device's screen in its own color (to check which tile is which physical machine)
    @objc func identifyScreens() {
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("identify \(pid)")
        }
        IdentifyGlow.shared.showSelf()
    }

    /// Make this device the mothership (source of layout distribution). From then on only the mothership distributes assignments
    @objc func becomeMothership() {
        UserDefaults.standard.set(LinkNet.machineID, forKey: "mothershipID")
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("mother \(pid)")
        }
        LayoutStore.apply(pos: LayoutStore.loadPos())
        window?.title = mothershipTitle()
    }

    private func mothershipTitle() -> String {
        guard let mid = UserDefaults.standard.string(forKey: "mothershipID") else { return "Layout Editor" }
        if mid == LinkNet.machineID { return "Layout Editor (this device is the mothership)" }
        return "Layout Editor (mothership: \(LayoutStore.name(of: mid)))"
    }
}

// MARK: - Snap to dialogs

/// The equivalent of Windows' "Move pointer to the default button".
/// When a dialog (including sheets) appears, move the cursor to the center of its default button.
/// Watch window creation of the frontmost app via Accessibility
final class DialogSnap {
    static let shared = DialogSnap()
    var enabled = UserDefaults.standard.bool(forKey: "snapToDialog")
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var seenWindows = Set<String>()
    private var workspaceObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    var onNote: ((String) -> Void)?

    func start() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.attachToFrontmost()
        }
        // Sheets send no creation notification, so periodically scan the frontmost app
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        attachToFrontmost()
    }

    private var sweepCounter = 0

    private func poll() {
        guard enabled else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        scan(appElement: AXUIElementCreateApplication(app.processIdentifier))
        // System dialogs (SecurityAgent, etc.) often don't appear as the frontmost app,
        // so also scan all running apps once every 2 seconds
        sweepCounter += 1
        if sweepCounter % 4 == 0 { sweepAllApps() }
    }

    private func sweepAllApps() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            if pid == selfPID || pid == frontPID { continue }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.25)
            scan(appElement: el)
        }
    }

    private func attachToFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier { return }
        let appEl = AXUIElementCreateApplication(pid)
        if pid == observedPID, observer != nil {
            scan(appElement: appEl)
            return
        }
        detach()
        observedPID = pid
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, element, _, _ in
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &r) == .success,
               (r as? String) == (kAXApplicationRole as String) {
                DialogSnap.shared.scan(appElement: element)
            } else {
                DialogSnap.shared.inspect(window: element)
            }
        }, &obs) == .success, let observer = obs else { return }
        _ = AXObserverAddNotification(observer, appEl, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        scan(appElement: appEl)
    }

    private func detach() {
        if let observer = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            self.observer = nil
        }
        observedPID = 0
    }

    /// Scan existing windows (for dialogs already showing, e.g. on app switch)
    func scan(appElement: AXUIElement) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        for w in windows {
            inspect(window: w)
            // Sheets hang off windows as children (AXSheet), so check children too
            var chRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &chRef) == .success,
               let children = chRef as? [AXUIElement] {
                for c in children {
                    var roleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &roleRef) == .success,
                       (roleRef as? String) == "AXSheet" {
                        inspect(window: c)
                    }
                }
            }
        }
    }

    /// Window identifier (to avoid moving to the same dialog twice)
    private func windowKey(_ window: AXUIElement) -> String {
        var pos = CGPoint.zero
        var size = CGSize.zero
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success, let posV = posRef {
            AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success, let sizeV = sizeRef {
            AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        }
        return "\(CFHash(window))|\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width)),\(Int(size.height))"
    }

    func inspect(window: AXUIElement) {
        guard enabled, !CursorShare.shared.anySessionActive else { return }
        let key = windowKey(window)
        if seenWindows.contains(key) { return }
        // Non-dialogs are recorded and not checked again. If it is a dialog but its buttons
        // aren't ready yet, don't record it and look again on the next scan
        guard isDialogLike(window) else { seenWindows.insert(key); return }
        var btnRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXDefaultButton" as CFString, &btnRef) == .success,
              let btn = btnRef else { return }
        let button = btn as! AXUIElement
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(button, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posV = posRef, let sizeV = sizeRef else { return }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return }
        let target = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        CGWarpMouseCursorPosition(target)
        // A warp alone changes only the "visible position", and clicks may land at the previous position.
        // Post one real event (mouseMoved) so the event-level mouse position matches too
        if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) {
            CursorShare.markSynthetic(mv)
            mv.post(tap: .cghidEventTap)
        }
        seenWindows.insert(key)
        if seenWindows.count > 200 { seenWindows.removeAll() }
        NetLog.shared.log("Dialog: moved to default button")
        onNote?("Moved to the dialog's default button")
    }

    /// True if it is a dialog itself or a sheet (whose parent is a window)
    private func isDialogLike(_ window: AXUIElement) -> Bool {
        var subRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subRef) == .success,
           let sub = subRef as? String,
           sub == (kAXDialogSubrole as String) || sub == (kAXSystemDialogSubrole as String) { return true }
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXParentAttribute as CFString, &parentRef) == .success,
           let parent = parentRef {
            var roleRef: CFTypeRef?
            let parentEl = parent as! AXUIElement
            if AXUIElementCopyAttributeValue(parentEl, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWindowRole as String) { return true }
        }
        return false
    }
}

/// Switcher sync: when window selection is confirmed on one device, close the Mission Control / Task View
/// open on the other devices with Esc
func switchKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // Listen-only tap to log traces of special keys such as the MC key (system-defined events)
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {
        let d1 = ns.data1
        // subtype=7 also fires on every click and was not the F3 signature (found by measurement on 2026-10-30).
        // Not used for detection; keep logging all of data1/data2 to continue identifying the signature
        NetLog.shared.log("System key: subtype=\(ns.subtype.rawValue) data1=0x\(String(d1, radix: 16)) data2=0x\(String(ns.data2, radix: 16))")
    }
    return Unmanaged.passUnretained(event)
}

final class SwitchSync {
    static let shared = SwitchSync()
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "switchSync") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "switchSync") }
    }
    private(set) var switching = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var lastFlagChangeAt = Date.distantPast   // For diagnostics: time the flags last changed
    var onNote: ((String) -> Void)?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
            self?.noteActivation(app: app)
        }
        // Trace special keys such as the MC key (listen-only tap)
        let sysMask = CGEventMask(1) << 14
        if let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: sysMask, callback: switchKeyCallback, userInfo: nil) {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// The app switched while the overview was open = selection was confirmed there
    private func noteActivation(app: String) {
        if switching {
            NetLog.shared.log("App switch detected: \(app)")
            guard enabled else { return }
            decide(reason: "app switch (\(app))")
        } else if Date().timeIntervalSince(lastFlagChangeAt) < 90 {
            // Also log unconfirmed app switches for a while right after sync (for troubleshooting)
            NetLog.shared.log("App switch detected: \(app) (not confirmed because switching=false)")
        }
    }

    /// We opened Mission Control: set the flag and send an "open" signal to other devices
    func noteLocalOpen() {
        guard enabled, !switching else { return }
        setFlag(true)
        broadcast("swopen")
        onNote?("Mission Control detected: signal sent")
    }

    /// Ctrl+↑ or the MC key: if not open, send an "opened" signal; if open, confirm (closed by toggle)
    func noteOpenKey() {
        guard enabled else { return }
        NetLog.shared.log("MC detected: noteOpenKey (switching=\(switching))")
        if switching { decide(reason: "key toggle") } else { noteLocalOpen() }
    }

    /// Four-finger vertical swipe on the trackpad (detected by Engine): swipe up opens the overview.
    /// A down swipe while switching is treated as "closed = confirmed".
    /// A down swipe does not open: that gesture is App Exposé, which is excluded from sync
    /// (Exposé shows the local app's windows and didn't line up with other devices' Mission Control, so it was unstable)
    func noteGesture(up: Bool) {
        guard enabled else { return }
        if !up && !switching { return }
        NetLog.shared.log("MC detected: vertical swipe (up=\(up))")
        if switching {
            if !up { decide(reason: "down swipe") }
        } else {
            noteLocalOpen()
        }
    }

    /// We closed the overview with Esc: treated like confirmation, so other devices' overviews close too
    func noteLocalEsc() {
        guard enabled, switching else { return }
        decide(reason: "Esc")
    }

    /// On receiving the signal, open our own Mission Control
    func openLocal() {
        // Sending Ctrl+↑ again while already open would close it via toggle
        guard enabled, !switching else { return }
        setFlag(true)
        onNote?("Received signal; opening Mission Control")
        postKey(126, flags: .maskControl)
    }

    /// Received "confirm" from another device: close with Esc only if the overview is open
    func receiveDone() {
        guard enabled, switching else { return }
        NetLog.shared.log("swdone received: closing with Esc")
        setFlag(false)
        postKey(53, flags: [])
    }

    private func decide(reason: String) {
        guard switching else { return }
        NetLog.shared.log("Confirmed: reason=\(reason)")
        setFlag(false)
        broadcast("swdone")
        onNote?("Confirmation sent")
    }

    private func broadcast(_ kind: String) {
        NetLog.shared.log("sent \(kind)")
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("\(kind) \(pid)")
        }
    }

    private func setFlag(_ on: Bool) {
        switching = on
        lastFlagChangeAt = Date()
        timer?.invalidate()
        timer = nil
        if on {
            let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                self?.setFlag(false)
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Reproduce the flags that real key events carry.
    /// Measured (key application log): a real Ctrl+↑ has kd flags 0xA40101, which differs greatly
    /// from the plain maskControl (0x40000). Arrow keys carry Fn (0x800000) and NumericPad (0x200000), all events carry
    /// NonCoalesced (0x100), and modifier keys carry left/right device bits (Ctrl=0x1, Shift=0x2, Cmd=0x8, Opt=0x20).
    /// The Dock's shortcut detection apparently accepts only this complete form
    private func realisticFlags(for keyCode: CGKeyCode, mods: CGEventFlags) -> CGEventFlags {
        var f = mods
        f.insert(.maskNonCoalesced)
        if mods.contains(.maskControl) { f.insert(CGEventFlags(rawValue: 0x1)) }
        if mods.contains(.maskShift) { f.insert(CGEventFlags(rawValue: 0x2)) }
        if mods.contains(.maskCommand) { f.insert(CGEventFlags(rawValue: 0x8)) }
        if mods.contains(.maskAlternate) { f.insert(CGEventFlags(rawValue: 0x20)) }
        if keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126 {
            f.formUnion([.maskSecondaryFn, .maskNumericPad])
        }
        if keyCode == 99 { f.insert(.maskSecondaryFn) }  // F3
        return f
    }

    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        // Send modifier keys independently as flagsChanged, and with a gap before the main key.
        // Sending everything at once may make the Dock's shortcut detection miss the modifier change,
        // so approximate a human press (modifier first, then the main key).
        // Make flags look just like the real thing (realisticFlags). The Dock doesn't recognize plain masks alone
        var mods: [(CGKeyCode, CGEventFlags)] = []
        if flags.contains(.maskControl) { mods.append((59, .maskControl)) }
        if flags.contains(.maskCommand) { mods.append((55, .maskCommand)) }
        if flags.contains(.maskAlternate) { mods.append((58, .maskAlternate)) }
        if flags.contains(.maskShift) { mods.append((56, .maskShift)) }
        let keyFlags = realisticFlags(for: keyCode, mods: flags)
        NetLog.shared.log("Key synthesis: code=\(keyCode) flags=\(flags.rawValue) real flags=\(keyFlags.rawValue)")
        var held: CGEventFlags = []
        for (mc, fl) in mods {
            held.insert(fl)
            postOne(mc, down: true, flags: realisticFlags(for: mc, mods: held), flagsChanged: true)
        }
        let step = 0.06
        let keyDelay = mods.isEmpty ? 0.0 : step
        DispatchQueue.main.asyncAfter(deadline: .now() + keyDelay) { [weak self] in
            self?.postOne(keyCode, down: true, flags: keyFlags, flagsChanged: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + keyDelay + step) { [weak self] in
            self?.postOne(keyCode, down: false, flags: keyFlags, flagsChanged: false)
        }
        if !mods.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + keyDelay + step * 2) { [weak self] in
                guard let self else { return }
                var rest = flags
                for (mc, fl) in mods.reversed() {
                    rest.remove(fl)
                    self.postOne(mc, down: false, flags: self.realisticFlags(for: mc, mods: rest), flagsChanged: true)
                }
            }
        }
    }

    private func postOne(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, flagsChanged: Bool) {
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) {
            e.flags = flags
            if flagsChanged { e.type = .flagsChanged }
            CursorShare.markSynthetic(e)
            e.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Search sync (⌘+Space)
/// Pressing ⌘+Space on any Mac opens search on the other devices too, and typed characters reach all devices.
/// Enter opens each device's top hit and closes; Esc / click / switching to another app closes search on all devices.
/// Only a Mac can be the origin (Windows only receives). IME conversion isn't sent, so this suits alphanumeric searches.
final class SearchSync {
    static let shared = SearchSync()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "searchSync") == nil ? true : UserDefaults.standard.bool(forKey: "searchSync") }
        set { UserDefaults.standard.set(newValue, forKey: "searchSync") }
    }

    private(set) var origin = false     // We are the origin (the side sending keystrokes)
    private(set) var receiving = false  // The side that opened search on receiving a signal
    private var timer: Timer?
    private var loggedApply = false
    private var openedAt = Date.distantPast
    private var originTextLen = 0
    var onNote: ((String) -> Void)?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated() {
        // Origin switched to another app = search ended
        if origin { noteLocalEnd() }
        // Receiver switched to another app = our search closed
        if receiving { receiving = false; disarm() }
    }

    private func sendAll(_ kind: String, _ rest: String? = nil) {
        for pid in LinkNet.peers.keys {
            LinkNet.sendFast(rest == nil ? "\(kind) \(pid)" : "\(kind) \(pid) \(rest!)")
        }
    }

    private func armTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: false) { [weak self] _ in self?.timeout() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func disarm() {
        timer?.invalidate(); timer = nil
    }
    private func timeout() {
        if origin { origin = false; sendAll("sdone") }
        // The receiver doesn't close via key synthesis. If the end signal never came, sending Esc late
        // would interrupt unrelated actions, so just quietly collapse the state
        receiving = false
        disarm()
    }

    // MARK: Origin side

    /// ⌘+Space was pressed locally
    func noteLocalOpen() {
        guard enabled, !receiving, !origin else { return }
        origin = true
        originTextLen = 0
        armTimer()
        sendAll("srch")
    }

    /// Origin's Esc: Esc while search text remains means "clear", not quit.
    /// Whether Spotlight is open can't be determined externally, so ignore focus targets and the like and
    /// decide by the number of keystrokes we forwarded (keep syncing while text exists; close all devices only when empty)
    func forwardKey(keycode: Int64) {
        guard origin else { return }
        if originTextLen > 0 {
            originTextLen = 0
            return
        }
        noteLocalEnd()
    }

    /// Send the origin's keystrokes to all devices in the same kd/ku/fl form as cursor sharing
    func forwardTypedKey(type: CGEventType, event: CGEvent) {
        guard origin else { return }
        let kind: String
        switch type {
        case .keyDown: kind = "kd"
        case .keyUp: kind = "ku"
        case .flagsChanged: kind = "fl"
        default: return
        }
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            // Track the search text length to decide what Esc means (clear or quit)
            if kc == 51 { originTextLen = max(0, originTextLen - 1) }
            else if kc != 36 && kc != 76 && kc != 48 && !(123...126).contains(kc) { originTextLen += 1 }
        }
        sendAll(kind, "\(kc) \(event.flags.rawValue)")
    }

    /// Origin's search ended: close other devices' search too
    func noteLocalEnd() {
        guard origin else { return }
        origin = false
        disarm()
        sendAll("sdone")
    }

    // MARK: Receiving side

    func receiveOpen() {
        guard enabled, !origin, !receiving else { return }
        receiving = true
        loggedApply = false
        openedAt = Date()
        armTimer()
        NetLog.shared.log("Search sync: receiver started")
        postKeyCode(49, flags: .maskCommand)
    }

    func receiveQuery(_ b64: String) {
        guard receiving else { return }
        // If our search isn't frontmost, assume it was closed and do nothing (prevents typing into another app by accident)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Spotlight" else {
            receiving = false
            disarm()
            return
        }
        let text = b64 == "~" ? "" : (Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        postReplaceText(text)
    }

    func receiveKey(_ which: String) {
        guard receiving else { return }
        if which == "bs" {
            postKeyCode(51)
        } else if which == "ret" {
            postKeyCode(36)
            receiving = false
            disarm()
        }
    }

    func receiveDone() {
        guard receiving else { return }
        receiving = false
        disarm()
        closeLocal()
    }

    /// Receiver: reproduce keystrokes (kd/ku/fl) arriving from the origin as they are.
    /// Whether Spotlight is open can't be determined externally (on macOS 27 the Spotlight window appears in neither
    /// CGWindowList nor as the frontmost app), so don't check; instead reproduce keys
    /// while syncing (receiving). Sync always ends via sdone / app switch / 30-second timeout
    func applyRemoteKey(kind: String, args: [String]) {
        guard receiving, args.count == 2, let code = UInt16(args[0]), let flagsRaw = UInt64(args[1]) else { return }
        if !loggedApply {
            loggedApply = true
            NetLog.shared.log("Search sync: started reproducing keystrokes")
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: kind != "ku") {
            e.flags = CGEventFlags(rawValue: flagsRaw)
            if kind == "fl" { e.type = .flagsChanged }
            CursorShare.markSynthetic(e)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Key synthesis

    private func postKeyCode(_ code: Int64, flags: CGEventFlags = []) {
        DispatchQueue.main.async {
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) {
                    e.flags = flags
                    CursorShare.markSynthetic(e)
                    e.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Close our own Spotlight. Spotlight's Esc works as "first = clear search text, second = close",
    /// so, like a human pressing twice, send it twice unconditionally with a gap.
    /// Don't use external open checks (AX focus target, etc.) since they're unreliable on the receiver
    private func closeLocal() {
        SwitchSync.shared.postKey(53, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SwitchSync.shared.postKey(53, flags: [])
        }
    }

    /// Select all in the search field, then replace its contents
    private func postReplaceText(_ s: String) {
        DispatchQueue.main.async {
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) {
                    e.flags = .maskCommand
                    CursorShare.markSynthetic(e)
                    e.post(tap: .cghidEventTap)
                }
            }
            if s.isEmpty {
                for down in [true, false] {
                    if let e = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: down) {
                        CursorShare.markSynthetic(e)
                        e.post(tap: .cghidEventTap)
                    }
                }
            } else {
                for ch in s {
                    let units = Array(String(ch).utf16)
                    for down in [true, false] {
                        if let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) {
                            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                            CursorShare.markSynthetic(e)
                            e.post(tap: .cghidEventTap)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Log (leave traces on all devices)
/// Record sends/receives and main actions both in memory and in Documents/cursor-log.txt
final class NetLog {
    static let shared = NetLog()
    private var lines: [String] = []
    private let lock = NSLock()
    private var fh: FileHandle?
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func start() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/cursor-log.txt")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let sz = attrs[.size] as? Int, sz > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        fh = try? FileHandle(forWritingTo: url)
        _ = fh?.seekToEndOfFile()
        log("=== started \(buildTag) ID=\(LinkNet.machineID) ===")
    }

    func log(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)"
        lock.lock()
        lines.append(line)
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        if let d = (line + "\n").data(using: .utf8) { fh?.write(d) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

final class LogWindowController: NSWindowController {
    private let tv = NSTextView()
    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Log"
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 440))
        sv.autoresizingMask = [.width, .height]
        sv.hasVerticalScroller = true
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sv.documentView = tv
        w.contentView?.addSubview(sv)
        super.init(window: w)
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        tv.string = NetLog.shared.text()
        tv.scrollToEndOfDocument(nil)
    }
}

// MARK: - App body

/// Menu bar "three fingers" icon (template image)
/// Menu bar "ワ" (OneManCursor). Use a rounded font if available, otherwise draw in bold
func fingerIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let font = NSFont(name: "HiraMaruProN-W8", size: 14.5) ?? NSFont(name: "HiraMaruProN-W4", size: 14.5) ?? NSFont.systemFont(ofSize: 14.5, weight: .bold)
        let s = "ワ" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black,
                                                    .strokeColor: NSColor.black, .strokeWidth: -5.0]
        let ts = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (18 - ts.width) / 2, y: (18 - ts.height) / 2), withAttributes: attrs)
        return true
    }
    img.isTemplate = true
    return img
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    lazy var cursorOverlay = CursorOverlay()
    var cursorShowItem: NSMenuItem!
    var cursorShapeItems: [NSMenuItem] = []
    var enabledItem: NSMenuItem!
    var remoteItem: NSMenuItem!
    var linkItem: NSMenuItem!
    var cursorItem: NSMenuItem!
    var layoutWC: LayoutWindowController?
    var tapItem: NSMenuItem!
    var lastItem: NSMenuItem!
    var mtItem: NSMenuItem!
    var statsItem: NSMenuItem!
    var diagItem: NSMenuItem!
    var pushItems: [NSMenuItem] = []
    var multItems: [NSMenuItem] = []
    var cursorAtItem: NSMenuItem!
    var snapItem: NSMenuItem!
    var switchItem: NSMenuItem!
    var searchItem: NSMenuItem!
    var soloItem: NSMenuItem!
    var logItem: NSMenuItem!
    private var logWC: LogWindowController?
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateDefaultsIfNeeded()
        // Since these are bundled under "Enabled", if legacy individual settings disagree, align them to "Enabled"
        let masterEnabled = Engine.shared.enabled
        if Engine.shared.linkMode != masterEnabled { Engine.shared.linkMode = masterEnabled; UserDefaults.standard.set(masterEnabled, forKey: "linkMode") }
        if CursorShare.shared.enabled != masterEnabled { CursorShare.shared.enabled = masterEnabled; UserDefaults.standard.set(masterEnabled, forKey: "cursorShare") }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = fingerIcon()
        let menu = NSMenu()
        let buildItem = NSMenuItem(title: buildTag, action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        cursorAtItem = NSMenuItem(title: "Cursor: this Mac", action: nil, keyEquivalent: "")
        cursorAtItem.isEnabled = false
        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        remoteItem = NSMenuItem(title: "Remote Control Mode (works over remote sessions too)", action: #selector(toggleRemote), keyEquivalent: "")
        remoteItem.target = self
        linkItem = NSMenuItem(title: "Partner Mode (send/receive signals over the network)", action: #selector(toggleLink), keyEquivalent: "")
        linkItem.target = self
        cursorItem = NSMenuItem(title: "Cursor Sharing (hand off at the edge)", action: #selector(toggleCursor), keyEquivalent: "")
        cursorItem.target = self
        snapItem = NSMenuItem(title: "Move Cursor to a Dialog's Default Button", action: #selector(toggleSnap), keyEquivalent: "")
        switchItem = NSMenuItem(title: "Mission Control / Task View Sync", action: #selector(toggleSwitch), keyEquivalent: "")
        switchItem.target = self
        searchItem = NSMenuItem(title: "Search Sync", action: #selector(toggleSearch), keyEquivalent: "")
        searchItem.target = self
        soloItem = NSMenuItem(title: "Solo mode", action: #selector(toggleSolo), keyEquivalent: "")
        soloItem.target = self
        logItem = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        logItem.target = self
        snapItem.target = self
        let layoutItem = NSMenuItem(title: "Edit Layout…", action: #selector(openLayoutEditor), keyEquivalent: "")
        layoutItem.target = self
        tapItem = NSMenuItem(title: "Use Session Mode for Key Sending", action: #selector(toggleTap), keyEquivalent: "")
        tapItem.target = self
        let moveParent = NSMenuItem(title: "Screen Transition Adjustments", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        let pushParent = NSMenuItem(title: "Edge Push Amount", action: nil, keyEquivalent: "")
        let pushMenu = NSMenu()
        pushItems = []
        for px in [0, 10, 20, 40, 80] {
            let pi = NSMenuItem(title: px == 0 ? "None (instant on touch)" : "\(px) px", action: #selector(pickPush(_:)), keyEquivalent: "")
            pi.target = self
            pi.tag = px
            pushMenu.addItem(pi)
            pushItems.append(pi)
        }
        pushParent.submenu = pushMenu
        let multParent = NSMenuItem(title: "Movement Multiplier", action: nil, keyEquivalent: "")
        let multMenu = NSMenu()
        multItems = []
        for m in [50, 75, 100, 125, 150, 200] {
            let mi = NSMenuItem(title: String(format: "%.2f×", Double(m) / 100), action: #selector(pickMult(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = m
            multMenu.addItem(mi)
            multItems.append(mi)
        }
        multParent.submenu = multMenu
        moveMenu.addItem(pushParent)
        moveMenu.addItem(multParent)
        moveParent.submenu = moveMenu
        lastItem = NSMenuItem(title: "Last detection: none", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        mtItem = NSMenuItem(title: "Trackpad: —", action: nil, keyEquivalent: "")
        mtItem.isEnabled = false
        statsItem = NSMenuItem(title: "Received: 0 frames / max 0 fingers", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        diagItem = NSMenuItem(title: "Show Status Details", action: #selector(toggleDiag), keyEquivalent: "")
        diagItem.target = self
        let permItem = NSMenuItem(title: "Open Device Control and Data Access Permission…", action: #selector(openPermSettings), keyEquivalent: "")
        permItem.target = self
        let screenItem = NSMenuItem(title: "Open Screen & System Audio Recording Permission…", action: #selector(openScreenSettings), keyEquivalent: "")
        screenItem.target = self
        let inputItem = NSMenuItem(title: "Open Input Monitoring Permission…", action: #selector(openInputSettings), keyEquivalent: "")
        inputItem.target = self
        menu.addItem(buildItem); menu.addItem(cursorAtItem); menu.addItem(.separator()); menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(snapItem); menu.addItem(switchItem); menu.addItem(searchItem); menu.addItem(soloItem); menu.addItem(layoutItem); menu.addItem(moveParent); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(diagItem); menu.addItem(logItem); menu.addItem(.separator())
        menu.addItem(permItem); menu.addItem(screenItem); menu.addItem(inputItem); menu.addItem(.separator())
        cursorShowItem = NSMenuItem(title: "Always Show Cursor", action: #selector(toggleCursorShow), keyEquivalent: "")
        cursorShowItem.target = self
        let shapeParent = NSMenuItem(title: "Cursor Shape", action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        cursorShapeItems = []
        for (i, name) in ["Arrow", "Circle", "Realistic"].enumerated() {
            let si = NSMenuItem(title: name, action: #selector(pickCursorShape(_:)), keyEquivalent: "")
            si.target = self
            si.tag = i
            shapeMenu.addItem(si)
            cursorShapeItems.append(si)
        }
        shapeParent.submenu = shapeMenu
        let cursorSettingsItem = NSMenuItem(title: "Cursor Display Settings…", action: #selector(openCursorSettings), keyEquivalent: "")
        cursorSettingsItem.target = self
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(cursorShowItem); menu.addItem(shapeParent); menu.addItem(cursorSettingsItem); menu.addItem(loginItem); menu.addItem(.separator())
        menu.delegate = self
        let relaunchItem = NSMenuItem(title: "Relaunch", action: #selector(relaunchSelf), keyEquivalent: "")
        relaunchItem.target = self
        menu.addItem(relaunchItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        applyDiagVisibility()
        refreshMenu()

        Engine.shared.onAction = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "Last detection: \(label)"
        }
        Engine.shared.onStats = { [weak self] frames, maxFingers in
            self?.statsItem.title = "Received: \(frames) frames / max \(maxFingers) fingers"
        }
        CursorShare.shared.onStatus = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "Last detection: \(label)"
        }
        if CursorShare.shared.enabled {
            CursorShare.shared.installTap()
            CursorShare.shared.requestInputAccessIfNeeded()
        }

        // Sending keys requires the Device Control and Data Access permission
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            alert("Device Control and Data Access permission is required",
                  "To send keys to Finder on swipe, allow OneManCursor in System Settings → Privacy & Security → Device Control and Data Access. After allowing it, relaunch OneManCursor.")
        }

        NetLog.shared.start()
        LinkNet.startReceiver()
        LinkNet.startHello()
        LinkNet.startTCP()
        DialogSnap.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "Last detection: \(label)"
        }
        DialogSnap.shared.start()
        SwitchSync.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "Last detection: \(label)"
        }
        SwitchSync.shared.start()
        SearchSync.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "Last detection: \(label)"
        }
        SearchSync.shared.start()

        cursorOverlay.start()
        refreshCursorMenu()

        let devices = Multitouch.start()
        mtItem.title = devices > 0 ? "Trackpad: connected (\(devices))" : "Trackpad: connection failed"
        startTrackpadWatchdog(initialDevices: devices)
        if devices == 0 {
            alert("Could not load the trackpad",
                  "Failed to open MultitouchSupport or detect a trackpad. The prototype method may not work on this Mac.")
        }
    }

    // MARK: Finger data monitoring (re-register automatically if it freezes)

    private var watchdogTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastDeviceCount = 0

    /// Trackpad finger data can freeze its registration after running a long time,
    /// reaching a state where "frames arrive but only one finger is read" (observed in practice).
    /// On wake from sleep, and when only one finger has been read for a set time,
    /// redo the registration so the app doesn't need relaunching
    private func startTrackpadWatchdog(initialDevices: Int) {
        lastDeviceCount = initialDevices
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reregisterTrackpads(reason: "wake from sleep")
        }
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(t, forMode: .common)
        watchdogTimer = t
    }

    private func watchdogTick() {
        let (frames, maxF) = Engine.shared.takeWindowStats()
        if frames >= 30 && maxF <= 1 {
            reregisterTrackpads(reason: "auto-detected")
        }
    }

    private func reregisterTrackpads(reason: String) {
        let n = Multitouch.start()
        NetLog.shared.log("Re-registered finger data: \(reason) (\(n) devices)")
        if n != lastDeviceCount {
            lastDeviceCount = n
            mtItem.title = n > 0 ? "Trackpad: connected (\(n))" : "Trackpad: connection failed"
        }
    }

    /// Carry over settings from the old apps (FinderSwipe and AlwaysCursor) (first run only).
    /// Important: without carrying over machineID, layout settings won't match other machines
    func migrateDefaultsIfNeeded() {
        let std = UserDefaults.standard
        guard !std.bool(forKey: "migrated.v1") else { return }
        for suite in ["local.finderswipe", "local.alwayscursor"] {
            guard let old = UserDefaults(suiteName: suite) else { continue }
            for (k, v) in old.dictionaryRepresentation() where std.object(forKey: k) == nil {
                std.set(v, forKey: k)
            }
        }
        std.set(true, forKey: "migrated.v1")
    }

    func refreshCursorMenu() {
        cursorShowItem?.state = cursorOverlay.showArrow ? .on : .off
        for si in cursorShapeItems { si.state = si.tag == cursorOverlay.shape ? .on : .off }
    }

    @objc func toggleCursorShow() {
        cursorOverlay.toggleArrow()
        refreshCursorMenu()
    }

    @objc func pickCursorShape(_ sender: NSMenuItem) {
        cursorOverlay.setShape(sender.tag)
        refreshCursorMenu()
    }

    @objc func openCursorSettings() {
        cursorOverlay.openSettings()
    }

    func refreshMenu() {
        enabledItem.state = Engine.shared.enabled ? .on : .off
        remoteItem.state = Engine.shared.remoteMode ? .on : .off
        linkItem.state = Engine.shared.linkMode ? .on : .off
        cursorItem.state = CursorShare.shared.enabled ? .on : .off
        snapItem.state = DialogSnap.shared.enabled ? .on : .off
        switchItem.state = SwitchSync.shared.enabled ? .on : .off
        searchItem.state = SearchSync.shared.enabled ? .on : .off
        soloItem.state = CursorShare.shared.soloMode ? .on : .off
        tapItem.state = Engine.shared.keyTapSession ? .on : .off
        diagItem.state = UserDefaults.standard.bool(forKey: "showDiag") ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for it in pushItems { it.state = it.tag == CursorShare.pushPx ? .on : .off }
        for it in multItems { it.state = it.tag == Int((CursorShare.moveMult * 100).rounded()) ? .on : .off }
        if let hid = CursorShare.shared.cursorAtID, hid != LinkNet.machineID {
            cursorAtItem.title = "Cursor: \(LayoutStore.name(of: hid))"
        } else {
            cursorAtItem.title = "Cursor: this Mac"
        }
    }

    var flashRestore: DispatchWorkItem?

    /// At the moment of detection, briefly dim the menu bar icon to notify
    func flashIcon() {
        guard let button = item.button else { return }
        flashRestore?.cancel()
        button.alphaValue = 0.25
        let work = DispatchWorkItem { [weak self] in self?.item.button?.alphaValue = 1.0 }
        flashRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    @objc func toggleEnabled() {
        // "Enabled" toggles swipe, partner (signal send/receive), and cursor sharing together
        let on = !Engine.shared.enabled
        Engine.shared.enabled = on
        UserDefaults.standard.set(on, forKey: "enabled")
        Engine.shared.linkMode = on
        UserDefaults.standard.set(on, forKey: "linkMode")
        if CursorShare.shared.enabled != on { CursorShare.shared.setEnabled(on) }
        refreshMenu()
    }

    @objc func toggleRemote() {
        Engine.shared.remoteMode.toggle()
        UserDefaults.standard.set(Engine.shared.remoteMode, forKey: "remoteMode")
        refreshMenu()
    }

    @objc func toggleLink() {
        Engine.shared.linkMode.toggle()
        UserDefaults.standard.set(Engine.shared.linkMode, forKey: "linkMode")
        refreshMenu()
    }

    @objc func toggleCursor() {
        CursorShare.shared.setEnabled(!CursorShare.shared.enabled)
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == item.menu { refreshCursorMenu(); refreshMenu() }
    }

    @objc func openLayoutEditor() {
        if layoutWC == nil {
            layoutWC = LayoutWindowController()
            layoutWC?.window?.center()
        }
        layoutWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Could not change the login item", error.localizedDescription)
        }
        refreshMenu()
    }

    @objc func toggleSnap() {
        DialogSnap.shared.enabled.toggle()
        UserDefaults.standard.set(DialogSnap.shared.enabled, forKey: "snapToDialog")
        refreshMenu()
    }

    @objc func toggleSwitch() {
        SwitchSync.shared.enabled.toggle()
        refreshMenu()
    }

    @objc func toggleSearch() {
        SearchSync.shared.enabled.toggle()
        refreshMenu()
    }

    @objc func toggleSolo() {
        CursorShare.shared.soloMode.toggle()
        if CursorShare.shared.soloMode { CursorShare.shared.enforceSolo() }
        refreshMenu()
    }

    @objc func showLog() {
        if logWC == nil { logWC = LogWindowController() }
        logWC?.refresh()
        logWC?.showWindow(nil)
        logWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func pickPush(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "edgePushPx")
        refreshMenu()
    }

    @objc func pickMult(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag) / 100, forKey: "moveMult")
        refreshMenu()
    }

    @objc func toggleDiag() {
        let v = !UserDefaults.standard.bool(forKey: "showDiag")
        UserDefaults.standard.set(v, forKey: "showDiag")
        applyDiagVisibility()
        refreshMenu()
    }

    /// The three lines (last detection, trackpad, received count) are for diagnostics. Keep them hideable normally
    private func applyDiagVisibility() {
        let v = UserDefaults.standard.bool(forKey: "showDiag")
        lastItem.isHidden = !v
        mtItem.isHidden = !v
        statsItem.isHidden = !v
    }

    /// For recovery when things misbehave: relaunch ourselves as a separate instance, then quit
    @objc func relaunchSelf() {
        LinkNet.sendReset()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func toggleTap() {
        Engine.shared.keyTapSession.toggle()
        UserDefaults.standard.set(Engine.shared.keyTapSession, forKey: "keyTapSession")
        refreshMenu()
    }

    @objc func openPermSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openInputSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openScreenSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func requestInputAccess() {
        CursorShare.shared.requestInputAccessNow()
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = App(); app.delegate = d
app.run()
