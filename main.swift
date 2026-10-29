import Cocoa
import ApplicationServices
import IOKit
import ServiceManagement
import UniformTypeIdentifiers

// OneManCursor: Finder でスワイプ操作するための常駐アプリ(試作)
// - 2本指の横フリック → 戻る(⌘[) / 進む(⌘])
// - 3本指の下スワイプ → 上の階層(⌘↑)、3本指の上スワイプ → 開く(⌘O)
// Finder が最前面のときだけ効く。指の動きは MultitouchSupport(Private)で直接読む。

// MARK: - MultitouchSupport の型(コミュニティで知られている定義)

struct MTPoint { var x: Float; var y: Float }
struct MTReadout { var position: MTPoint; var velocity: MTPoint }
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32          // 3 = 触れた, 4 = 触れている
    var finger: Int32
    var hand: Int32
    var normalized: MTReadout // 位置は 0...1 に正規化(y は上が +)
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
    case back = "戻る"
    case forward = "進む"
    case parent = "上の階層へ"
    case open = "開く"

    /// 相方連携で送る合図の名前
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

// MARK: - 判定エンジン

final class Engine {
    static let shared = Engine()
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var remoteMode = UserDefaults.standard.bool(forKey: "remoteMode")
    var linkMode = UserDefaults.standard.bool(forKey: "linkMode")
    var keyTapSession = UserDefaults.standard.bool(forKey: "keyTapSession")
    var onAction: ((String) -> Void)?
    var onStats: ((Int, Int) -> Void)?

    // 診断用: コールバックが来ているか、指の数が読めているか
    private(set) var frames = 0
    private(set) var maxFingers = 0
    private var lastStatsPush: Double = 0

    func noteFrame(rawCount: Int, timestamp: Double) {
        frames += 1
        if rawCount > maxFingers { maxFingers = rawCount }
        if timestamp - lastStatsPush > 0.25 {
            lastStatsPush = timestamp
            let f = frames, m = maxFingers
            DispatchQueue.main.async { [weak self] in self?.onStats?(f, m) }
        }
    }

    private var session = false
    private var lockedCount = 0       // セッション中に確認した最大の指の数(2 か 3)
    private var startX: Float = 0, startY: Float = 0
    private var startT: Double = 0
    private var fired = false

    // しきい値(正規化座標 0...1 に対する割合)
    private let flickMin: Float = 0.20     // 2本指フリックの最小移動量
    private let vertMin: Float = 0.20      // 3本指の最小移動量
    private let flickMaxTime = 0.6         // 2本指はこの時間内に大きく動いたものだけ拾う
    private let graceTime = 0.09           // 3本目が遅れて触れるのを待つ時間

    func handle(_ fingers: [Finger], timestamp: Double) {
        let downs = fingers.filter { $0.state == 3 || $0.state == 4 }
        if downs.isEmpty { session = false; fired = false; lockedCount = 0; return }
        let n = downs.count
        let cx = downs.reduce(Float(0)) { $0 + $1.normalized.position.x } / Float(n)
        let cy = downs.reduce(Float(0)) { $0 + $1.normalized.position.y } / Float(n)

        if !session {
            guard n >= 2 else { return }
            session = true; lockedCount = n
            startX = cx; startY = cy; startT = timestamp; fired = false
            return
        }
        if n > lockedCount { lockedCount = n }
        guard !fired, n >= 2 else { return }
        let dx = cx - startX, dy = cy - startY
        let elapsed = timestamp - startT

        if lockedCount == 2 {
            // 横フリック: 右へ = 戻る、左へ = 進む(Safari と同じ向き)
            guard elapsed >= graceTime, elapsed <= flickMaxTime else { return }
            if abs(dx) >= flickMin, abs(dx) >= 2 * abs(dy) {
                fire(dx > 0 ? .back : .forward)
            }
        } else if lockedCount == 3 {
            // 縦: 下へ = 上の階層、上へ = 開く
            if abs(dy) >= vertMin, abs(dy) >= 2 * abs(dx) {
                fire(dy > 0 ? .open : .parent)
            }
        }
    }

    private func fire(_ action: SwipeAction) {
        fired = true
        // 送ってよい場面: Finder が最前面のとき。
        // リモート操作モードでは Moonlight が最前面のときも送る(キーは Moonlight 経由で相手側に届く)
        let front = NSWorkspace.shared.frontmostApplication
        let isFinder = front?.bundleIdentifier == "com.apple.finder"
        let isRemote = remoteMode && front?.localizedName == "Moonlight"
        var note = ""
        if !enabled {
            note = "（無効中）"
        } else if CursorShare.shared.sessionActiveAway {
            // カーソル共有で相手を操作中なら、スワイプもキー入力として相手に送る
            CursorShare.shared.forwardActionKey(for: action)
            note = "（カーソル共有で送信）"
        } else if isFinder {
            postKey(for: action)
        } else if isRemote {
            postKey(for: action)
        } else {
            note = "（対象のアプリ以外のため送信なし）"
        }
        let label = action.rawValue + note
        DispatchQueue.main.async { [weak self] in self?.onAction?(label) }
    }

    /// 相方から合図が届いたとき。自分の Finder が最前面のときだけ実行する
    func receiveLink(_ wire: String) {
        guard enabled, linkMode else { return }
        guard let action = SwipeAction.fromWire(wire) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == "com.apple.finder" else { return }
        postKey(for: action)
        let label = "合図を受信： \(action.rawValue)"
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
        // ユニバーサルコントロールが拾う経路を探るため、送信方式を切り替えられるようにしている
        let tap: CGEventTapLocation = keyTapSession ? .cgSessionEventTap : .cghidEventTap
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) {
                e.flags = .maskCommand
                e.post(tap: tap)
            }
        }
    }
}

// MARK: - 相方連携(同じネットワーク内で合図を送り合う)

// ユニバーサルコントロールは「本物のキーボード入力」しか相手側へ転送せず、
// アプリが合成したキーはどちらの送信方式でも届かなかった(実機で確認済み)。
// そこで、スワイプの「合図」だけを UDP ブロードキャストで送り、
// 受け側の OneManCursor が自分の Finder にキーを送る形にする。
// 注意: 同じ LAN 内なら誰でも合図を送れてしまう試作仕様(家庭内利用前提)。
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

    /// 発見した相方(id → 名前・IP・最終確認時刻)
    private(set) static var peers: [String: (name: String, ip: String, seen: Date)] = [:]
    /// 相手の画面サイズ(hello で申告される。レイアウト編集のタイル比率に使う)
    static var peerSizes: [String: (w: Int, h: Int)] = [:]

    // TCP 直結(到達と順序が保証されるので、キーの欠け対策の本命)
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

    /// 接続済みの全相方へ TCP で送る(つながっていない相手は UDP 側で拾う)
    private static func sendToAllPeers(_ text: String) {
        connsLock.lock()
        let list = Array(conns.values)
        connsLock.unlock()
        for c in list { _ = c.sendLine(text) }
    }

    /// 名乗りを送り始める(レイアウト設定で相方を見つけるため)
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

    /// カーソル共有セッションの全体リセット
    static func sendReset() {
        let text = magic + "\(machineID) 0 reset"
        sendToAllPeers(text)
        udpSend(text)
    }

    /// 自分の識別子(自分の送った合図を自分で受けないため)
    static let machineID: String = {
        if let s = UserDefaults.standard.string(forKey: "machineID") { return s }
        let s = String(UInt32.random(in: 0..<UInt32.max), radix: 16)
        UserDefaults.standard.set(s, forKey: "machineID")
        return s
    }()

    private static func udpSend(_ text: String, toIP ip: String? = nil) {
        // 送信用ソケットは1つを使い回す(合図のたびに作り直すとマウス移動が重くなる)
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

    /// スワイプの合図(TCP で全相方へ送り、つながっていない相手向けに UDP でも3回送る)
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

    /// カーソル共有の細かい合図。送信は専用キューに逃がし、動き(mv)は約6ms分をまとめて送る
    /// (タップの中で同期送信したり、1イベントごとに送ったりすると全体が重くなるため)
    static func sendFast(_ body: String) {
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
            // キーやクリックなどの「出来事」は落とすと致命的。TCP があれば1回で確実に届き、
            // 無ければ UDP で同じ連番を3回送る(受け側で重複を捨てる)
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
        // TCP が無い相手(Windows など)には、IP が分かればユニキャストで送る。
        // Wi-Fi のブロードキャストは遅延と落下が多く、カクつきと合図落ちの原因になるため
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

    /// 宛先の相手と TCP でつながっていれば、そちらで送る。送れたら true
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

    /// 合図1つ分の処理(UDP でも TCP でも共通)
    static func handlePacket(_ s: String, ip: String) {
        guard s.hasPrefix(magic) else { return }
        let parts = s.dropFirst(magic.count).split(separator: " ")
        guard parts.count >= 3, String(parts[0]) != machineID, let seq = UInt64(parts[1]) else { return }
        let kind = String(parts[2])
        if kind == "hello" {
            var tokens = parts.dropFirst(3).map { String($0) }
            // 末尾の解像度トークン(例 2560x1440)は名前ではないので分ける
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
            CursorShare.shared.resetSession()
            return
        }
        if kind == "clip" {
            // クリップボードの断片: 同じ連番の再送は1回だけ処理する
            let dupKey = "\(parts[0])-\(seq)"
            let nowFast = Date().timeIntervalSince1970
            if let seen = seenFast[dupKey], nowFast - seen < 2 { return }
            seenFast[dupKey] = nowFast
            seenFast = seenFast.filter { nowFast - $0.value < 10 }
            ClipShare.shared.receive(args: parts.dropFirst(3).map { String($0) }, from: String(parts[0]))
        } else if SwipeAction.fromWire(kind) != nil {
            // スワイプの合図: 複数回・複数経路で届く同じものは1回だけ実行する
            let now = Date().timeIntervalSince1970
            if let seen = seenSeqs[seq], now - seen < 2 { return }
            seenSeqs[seq] = now
            seenSeqs = seenSeqs.filter { now - $0.value < 10 }
            Engine.shared.receiveLink(kind)
        } else {
            // カーソル共有の合図: UDP では3回送られてくるので、同じ連番は1回だけ処理する
            let dupKey = "\(parts[0])-\(seq)"
            let nowFast = Date().timeIntervalSince1970
            if let seen = seenFast[dupKey], nowFast - seen < 2 { return }
            seenFast[dupKey] = nowFast
            seenFast = seenFast.filter { nowFast - $0.value < 10 }
            CursorShare.shared.receive(kind, args: parts.dropFirst(3).map { String($0) }, from: String(parts[0]))
        }
    }

    // MARK: TCP 直結

    static func startTCP() {
        // 受け付け側
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
        // つなぎに行く側: 重複を避けるため、ID が小さい方が相手に接続する
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

    /// 1接続の読み取り。先頭の FSHELLO で相手を確認し、以降は合図を1行ずつ処理する
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

// MARK: - カーソル共有(試作)

func cursorTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    CursorShare.shared.handle(type: type, event: event)
}

/// 相方がいる方向。レイアウトは「方向 → 相方のマシンID」で持ち、3台以上でも数珠つなぎに渡せる
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

/// 隣接リンク: 方向 + 相手 + 自分の辺のうち相手と重なる範囲(割合)。
/// ずらした配置では辺の一部だけが重なるため、範囲を持つ
struct PeerLink {
    var dir: PartnerDir
    var id: String
    var start: Double
    var end: Double
    /// 保存・配信用("相手ID"、範囲が一部のときは "相手ID@開始@終了")
    var spec: String {
        if start <= 0.0005 && end >= 0.9995 { return id }
        return "\(id)@\(String(format: "%.3f", start))@\(String(format: "%.3f", end))"
    }
}

/// カーソル共有の試作。
/// 起点の Mac はイベントタップでマウスとキーを横取りし、宛先付きの合図に変えて送る。
/// 受けた Mac は自分の画面で再現し、さらに隣がいる端を越えたら次の相手へ中継する。
/// Esc は非常口: 起点ではセッション終了、参加者では全体リセットを合図する。
final class CursorShare {
    static let shared = CursorShare()
    var enabled = UserDefaults.standard.bool(forKey: "cursorShare")
    var onStatus: ((String) -> Void)?

    /// 隣接リンクの表(レイアウトから導かれる。手動設定の置き場もここ)
    private(set) var links: [PeerLink] = []

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    // セッションの状態(同時に1つだけ)
    private var sending = false      // 自分が起点(タップで入力を横取り中)
    private var awayTo: String?      // 起点のとき: カーソルを渡している相手
    private var holding = false      // カーソルが自分の画面にある(他機起点)
    private var cameFrom: String?    // 保持者のとき: 渡してきた相手
    private var forwardTo: String?   // 中継中: さらに先の相手
    private var vx: Double = 0, vy: Double = 0

    // 画面移動の調整(メニュー「画面移動の調整」で変更)
    /// 端の押し込み量(px)。0 = 端に触れたら即移動
    static var pushPx: Int { UserDefaults.standard.integer(forKey: "edgePushPx") }
    /// 起点が送るカーソル移動の倍率。未設定(0)なら 1
    static var moveMult: Double {
        let v = UserDefaults.standard.double(forKey: "moveMult")
        return v == 0 ? 1 : v
    }
    private var edgePush: [PartnerDir: Double] = [:]   // 起点側: 端への押し込み累積
    private var holdPush: [PartnerDir: Double] = [:]   // 保持側: 端への押し込み累積
    private var multAccX = 0.0, multAccY = 0.0         // 倍率の端数を持ち越す

    private init() {
        // 新形式(linksV2)を読み、無ければ旧形式(neighbor_*)から移行する
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

    /// 保存・配信用の文字列からリンク表を復元する("right=id@0.00@0.50;left=id2" 形式)
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

    /// リンク表を丸ごと差し替える(レイアウトの割り当て・エディタから)
    func setLinks(_ newLinks: [PeerLink]) {
        links = newLinks
        saveLinks()
    }

    /// 合図で入ってきた相手を、その方向の隣として覚える(自動学習)。
    /// 同じ相手が既にその方向にいる(スパン付きの割り当て含む)なら壊さない
    func learnLink(dir: PartnerDir, id: String) {
        if links.contains(where: { $0.dir == dir && $0.id == id }) { return }
        links.removeAll { $0.id == id }
        links.removeAll { $0.dir == dir }
        links.append(PeerLink(dir: dir, id: id, start: 0, end: 1))
        saveLinks()
    }

    /// その方向の、辺の位置 ratio に重なっているリンク
    func link(dir: PartnerDir, at ratio: Double) -> PeerLink? {
        links.first { $0.dir == dir && ratio >= $0.start - 0.001 && ratio <= $0.end + 0.001 }
    }

    func link(toPeer id: String) -> PeerLink? { links.first { $0.id == id } }

    func dir(ofPeer id: String) -> PartnerDir? { link(toPeer: id)?.dir }

    /// 相手から届いた「共有辺の中の位置」を、自分の辺の位置に直す
    func entryRatio(forPeer id: String, seg: Double) -> Double {
        guard let lk = link(toPeer: id) else { return seg }
        return lk.start + seg * (lk.end - lk.start)
    }

    private func peerName(_ id: String) -> String {
        LinkNet.peers[id]?.name ?? "相手"
    }

    /// 全ディスプレイの外形(複数ディスプレイはこの外形で近似する)
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
        showCursor()
        stopPinning()
        EdgeGlow.shared.hide()
    }

    private var frozenPoint: CGPoint?
    private var pinTimer: Timer?

    /// 渡している間、起点側のカーソルを渡した地点に固定し続ける。
    /// 非表示が効かない環境(UC の描画など)でも、少なくとも手の動きについて回らなくなる
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

    /// 操作を渡している間、起点側のカーソルは隠す(見えていると誤タップの元になるため)。
    /// クリック自体はタップで飲んでいるのでアプリには届かないが、見た目も消しておく。
    /// 隠す回数を数えておき、戻すときは同じ回数だけ表示する(固定タイマーから何度も隠すため)
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

    /// 入力監視への「登録」だけ自動で行う。
    /// アプリ側から許可を求めると、システムの確認が出て、設定のリストに自動で載る(スイッチは切れたまま)。
    /// スイッチをオンにすること自体は macOS の仕様でユーザー操作でしかできない。
    func requestInputAccessIfNeeded() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    /// メニューから明示的に許可を求める版。macOS が見ている状態を「最後の検出」に出して切り分ける
    func requestInputAccessNow() {
        let before = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        // HID 層でキー入力の「聞くだけタップ」を作る試みも、設定リストへの登録の引き金になるので併用する
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
        case kIOHIDAccessTypeGranted: label = "許可済み"
        case kIOHIDAccessTypeDenied: label = "拒否済み（設定で変更が必要）"
        default: label = "未確認"
        }
        status("入力監視： \(label) / リクエスト \(ok ? "OK" : "NG") / HIDタップ \(probeOK ? "作成可" : "作成不可")")
    }

    // MARK: イベントタップ(起点と、参加中の物理入力の扱い)

    func installTap() {
        guard tap == nil else { return }
        var mask: CGEventMask = 0
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        for t in types { mask |= (CGEventMask(1) << CGEventMask(t.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cursorTapCallback, userInfo: nil) else {
            status("カーソル共有： タップを作れませんでした（許可を確認してください）")
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

    /// 自分が合成したイベントにつける目印(自分のタップで飲まないため)
    private static let syntheticMarker: Int64 = 0x4653_5750

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // 自分が合成したイベントは素通しする(保持者として post したクリックやスクロールを、
        // 自分のタップの「参加中は物理マウスを飲む」ルールで消してしまわないため)
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }
        // 手元にカーソルがあるときは、端への近さでボーダー表示を更新する
        if enabled, !sending, !holding, forwardTo == nil,
           type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            updateGlowAtHome(event.location)
        }
        // 非常口は ⌘Esc。Esc 単体はよく使うキーなので、普通のキーとして相手へ送る
        let isEsc = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 && event.flags.contains(.maskCommand)

        // 他機起点のセッションに参加中(保持者・中継者): 物理マウスは位置がずれるので飲む。⌘Esc で全体リセット
        if holding || forwardTo != nil {
            if isEsc {
                LinkNet.sendReset()
                resetSession()
                status("カーソル共有： リセットしました")
                return nil
            }
            if isMouse(type) { return nil }
            return Unmanaged.passUnretained(event)
        }

        // 自分が起点
        if sending {
            if awayTo == nil {
                // カーソルは手元にある: 通常どおり通しつつ、端を監視する。⌘Esc で自分のセッション状態を掃除する
                if isEsc { resetSession() }
                if isMove(type), checkEdges(event) { return nil }
                return Unmanaged.passUnretained(event)
            }
            // カーソルは相手側: ⌘Esc で終了、それ以外は合図に変えて飲む
            if isEsc {
                LinkNet.sendReset()
                resetSession()
                status("カーソル共有： 終了しました")
                return nil
            }
            forwardPhysical(type: type, event: event, to: awayTo!)
            return nil
        }

        // 待機中: 端に触れたらセッション開始
        if isMove(type), checkEdges(event) { return nil }
        return Unmanaged.passUnretained(event)
    }

    /// 自分が起点で、カーソルが相手側にある状態か
    var sessionActiveAway: Bool { sending && awayTo != nil }

    /// スワイプのアクションを、相手へのキー入力(⌘付き)として送る
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

    /// 端から 56px 以内に入ったら、その方向の行き先をボーダーで示す(起点・手元のとき)
    private func updateGlowAtHome(_ loc: CGPoint) {
        let b = allBounds
        let spots: [(PartnerDir, Double, Double)] = [
            (.right, Double(b.maxX) - Double(loc.x), (Double(loc.y) - Double(b.minY)) / Double(b.height)),
            (.left, Double(loc.x) - Double(b.minX), (Double(loc.y) - Double(b.minY)) / Double(b.height)),
            (.down, Double(b.maxY) - Double(loc.y), (Double(loc.x) - Double(b.minX)) / Double(b.width)),
            (.up, Double(loc.y) - Double(b.minY), (Double(loc.x) - Double(b.minX)) / Double(b.width)),
        ]
        for (dir, dist, ratio) in spots where dist <= 56 {
            if let lk = link(dir: dir, at: ratio) {
                EdgeGlow.shared.show(dir: dir, link: lk)
                return
            }
        }
        EdgeGlow.shared.hide()
    }

    /// 保持中: 仮想カーソルの端への近さでボーダーを示す
    private func updateGlowHolding() {
        let b = allBounds
        let spots: [(PartnerDir, Double, Double)] = [
            (.right, Double(b.maxX) - vx, (vy - Double(b.minY)) / Double(b.height)),
            (.left, vx - Double(b.minX), (vy - Double(b.minY)) / Double(b.height)),
            (.down, Double(b.maxY) - vy, (vx - Double(b.minX)) / Double(b.width)),
            (.up, vy - Double(b.minY), (vx - Double(b.minX)) / Double(b.width)),
        ]
        for (dir, dist, ratio) in spots where dist <= 56 {
            if let lk = link(dir: dir, at: ratio) {
                EdgeGlow.shared.show(dir: dir, link: lk)
                return
            }
        }
        EdgeGlow.shared.hide()
    }

    /// 端に触れていたら相手に渡す。渡したら true
    /// 押し込み量が設定されているときは、端に張り付いたまま外向きに押し込んだ
    /// 合計がその量に達するまで渡さない(端でのバタつき防止にもなる)
    private func checkEdges(_ event: CGEvent) -> Bool {
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
            // 渡す位置は「共有辺の中の割合」に正規化する(ずらした配置でも位置が合うように)
            let seg = lk.end > lk.start ? min(1, max(0, (ratio - lk.start) / (lk.end - lk.start))) : 0.5
            sending = true
            awayTo = lk.id
            edgePush.removeAll()
            multAccX = 0; multAccY = 0
            for _ in 0..<3 { LinkNet.sendFast("enter \(lk.id) \(seg) \(dir.rawValue)") }
            hideCursor()
            startPinning(at: loc)
            EdgeGlow.shared.hide()
            status("カーソル共有： \(peerName(lk.id)) に渡しました")
            return true
        }
        return false
    }

    /// 起点の物理入力を合図に変える
    private func forwardPhysical(type: CGEventType, event: CGEvent, to: String) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getIntegerValueField(.mouseEventDeltaX)
            let dy = event.getIntegerValueField(.mouseEventDeltaY)
            let mult = Self.moveMult
            if mult == 1 {
                if dx != 0 || dy != 0 { LinkNet.sendFast("mv \(to) \(dx) \(dy)") }
            } else {
                // 倍率をかけ、端数は持ち越す(ゆっくり動かした分が消えないように)
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
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if dx != 0 || dy != 0 { LinkNet.sendFast("sc \(to) \(Int(dy)) \(Int(dx))") }
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

    // MARK: 受け側(LinkNet から呼ばれる。args の先頭は宛先ID)

    func receive(_ kind: String, args: [String], from: String) {
        guard enabled, let to = args.first, to == LinkNet.machineID else { return }
        let rest = Array(args.dropFirst())
        switch kind {
        case "enter":
            guard rest.count >= 1 else { return }
            let seg = Double(rest[0]) ?? 0.5
            // 送り手の出た方向が付いていれば、その反対側の隣として覚える(割り当てが無い環境向けの自動学習)
            if rest.count >= 2, let exitDir = PartnerDir(rawValue: rest[1]) {
                learnLink(dir: exitDir.opposite, id: from)
            }
            if sending, awayTo != nil {
                // 輪を一周して起点(自分)に帰ってきた。セッションを畳み、全体へリセットをかけて
                // 中継者たちの状態も揃える
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
                status("カーソル共有： 一周して戻りました")
                return
            }
            // 自分が起点でも、カーソルが手元に戻っている状態なら受け取れる(セッションは相手に譲る)。
            // ここで弾くと「一度送った側には二度と戻せない」非対称な詰まりになる
            guard awayTo == nil, !holding, forwardTo == nil else { return }
            sending = false
            holding = true
            cameFrom = from
            if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)) }
            warp()
            status("カーソル共有： \(peerName(from)) から受け取りました")
        case "leave":
            guard rest.count >= 1 else { return }
            let seg = Double(rest[0]) ?? 0.5
            if awayTo == from {
                // 起点にカーソルが戻ってきた(セッション自体は継続)
                awayTo = nil
                showCursor()
                stopPinning()
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)); warp() }
                status("カーソル共有： 手元に戻りました")
            } else if forwardTo == from {
                // 中継していた先から戻ってきた → 自分が保持者になる(cameFrom は元の相手のまま)
                forwardTo = nil
                holding = true
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)); warp() }
                status("カーソル共有： 戻ってきました")
            }
        case "assign":
            // レイアウトの割り当て: リンク表を丸ごと差し替える
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
            status("レイアウト： 割り当てを受けました")
        case "mv", "dn", "up", "sc", "kd", "ku", "fl":
            if holding {
                apply(kind, args: rest)
            } else if let fwd = forwardTo {
                // 中継: 宛先を次の相手に書き換えてそのまま送る
                LinkNet.sendFast("\(kind) \(fwd) " + rest.joined(separator: " "))
            }
        default:
            break
        }
    }

    /// 端の位置に仮想カーソルを置く
    private func positionAtEdge(_ dir: PartnerDir, ratio: Double) {
        let b = allBounds
        switch dir {
        case .right: vx = Double(b.maxX) - 1; vy = Double(b.minY) + ratio * Double(b.height)
        case .left: vx = Double(b.minX); vy = Double(b.minY) + ratio * Double(b.height)
        case .down: vy = Double(b.maxY) - 1; vx = Double(b.minX) + ratio * Double(b.width)
        case .up: vy = Double(b.minY); vx = Double(b.minX) + ratio * Double(b.width)
        }
    }

    /// 端を越えたときの受け渡し・返却。実行したら true
    private func cross(_ dir: PartnerDir, ratio: Double) -> Bool {
        guard let lk = link(dir: dir, at: ratio) else { return false }
        let seg = lk.end > lk.start ? min(1, max(0, (ratio - lk.start) / (lk.end - lk.start))) : 0.5
        let next = lk.id
        if next == cameFrom {
            LinkNet.sendFast("leave \(next) \(seg)")
            holding = false
            cameFrom = nil
            status("カーソル共有： 手元に返しました")
        } else {
            LinkNet.sendFast("enter \(next) \(seg) \(dir.rawValue)")
            forwardTo = next
            holding = false
            status("カーソル共有： \(peerName(next)) へ渡しました")
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
                // 端に張り付いたまま押し込んだ量が設定値に達したら渡す
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

    /// 受け側の移動は「本物のマウス移動イベント」として流す。
    /// ワープだけだと Dock の自動表示やホバーなど、移動イベントを見る仕組みが反応しないため
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

    /// 受け側のカーソル移動は最大で約8msに1回に間引く(合図のたびにワープさせると重くなるため)
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

// MARK: - MultitouchSupport の読み込み

final class Multitouch {
    typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
    typealias RegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback) -> Void
    typealias StartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private static var retainedList: CFMutableArray?

    /// 接続できたデバイス数を返す(0 = 失敗)
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



// MARK: - マシンの色と端のボーダー表示

/// "#RRGGBB" から NSColor を作る
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

/// マシンの色: 設定済みならそれ、無ければ ID から安定して決まる色
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

/// 端に近づいたとき、行き先のマシンの色で画面の輪郭を光らせる表示。
/// 行き先の区間を強く光らせるので、色の切れ目が隣同士の境界になる
final class EdgeGlow {
    static let shared = EdgeGlow()
    private var window: NSWindow?
    private var view: EdgeGlowView?
    private var timer: Timer?
    fileprivate var alpha = 0.0
    private var targetAlpha = 0.0
    fileprivate var dir: PartnerDir = .right
    fileprivate var color: NSColor = .systemBlue
    fileprivate var segStart = 0.0
    fileprivate var segEnd = 1.0

    func show(dir: PartnerDir, link lk: PeerLink) {
        let c = colorFromHex(machineColorHex(of: lk.id))
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.ensureWindow()
            self.dir = dir
            self.color = c
            self.segStart = lk.start
            self.segEnd = lk.end
            self.targetAlpha = 1
            self.startTimer()
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.targetAlpha = 0
            self?.startTimer()
        }
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
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window = w
        view = v
    }

    private func startTimer() {
        if timer != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
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
    }
}

final class EdgeGlowView: NSView {
    weak var owner: EdgeGlow?

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner, o.alpha > 0.01 else { return }
        let a = CGFloat(o.alpha)
        let col = o.color
        // 輪郭全体をうっすら
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 14, yRadius: 14)
        col.withAlphaComponent(0.30 * a).setStroke()
        outline.lineWidth = 4
        outline.stroke()
        // 行き先の区間を強く(影でぼかす)
        let w = Double(bounds.width), h = Double(bounds.height)
        let s = o.segStart, e = o.segEnd
        let seg = NSBezierPath()
        switch o.dir {
        case .right:
            seg.move(to: NSPoint(x: w - 4, y: h * (1 - s)))
            seg.line(to: NSPoint(x: w - 4, y: h * (1 - e)))
        case .left:
            seg.move(to: NSPoint(x: 4, y: h * (1 - s)))
            seg.line(to: NSPoint(x: 4, y: h * (1 - e)))
        case .down:
            seg.move(to: NSPoint(x: w * s, y: 4))
            seg.line(to: NSPoint(x: w * e, y: 4))
        case .up:
            seg.move(to: NSPoint(x: w * s, y: h - 4))
            seg.line(to: NSPoint(x: w * e, y: h - 4))
        }
        let shadow = NSShadow()
        shadow.shadowColor = col.withAlphaComponent(0.9 * a)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        col.withAlphaComponent(0.95 * a).setStroke()
        seg.lineWidth = 5
        seg.lineCapStyle = .round
        seg.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - レイアウト配置

/// 配置(マシンID → 原点)と、そこから導く隣接リンク、割り当ての送信を担当する
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

    /// 初回用: 既存のリンク(自分の隣)から配置を組み立てる
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

    /// 配置から全マシンのリンク表を導く(辺が接し、30px以上重なる相手が隣)
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
        return result
    }

    /// 配置を保存し、自分のリンクへ反映し、他の全マシンへ割り当てを送る
    static func apply(pos: [String: (x: Double, y: Double)]) {
        savePos(pos)
        let all = derive(rects: rects(pos: pos))
        CursorShare.shared.setLinks(all[LinkNet.machineID] ?? [])
        for (id, lks) in all where id != LinkNet.machineID { sendAssign(to: id, links: lks) }
        let members = Set(UserDefaults.standard.stringArray(forKey: "layoutMembers") ?? [])
        for id in members where pos[id] == nil && id != LinkNet.machineID { sendAssign(to: id, links: []) }
        UserDefaults.standard.set(Array(pos.keys), forKey: "layoutMembers")
    }

    static func sendAssign(to id: String, links: [PeerLink]) {
        var tokens = links.isEmpty ? ["none"] : links.map { "\($0.dir.rawValue)=\($0.spec)" }
        // 色の対応表も一緒に配る(端のボーダー表示で使う)
        for cid in loadPos().keys {
            tokens.append("c:\(cid)=\(machineColorHex(of: cid))")
        }
        LinkNet.sendFast("assign \(id) " + tokens.joined(separator: " "))
        lastAssign[id] = Date()
    }

    private static var lastAssign: [String: Date] = [:]

    /// hello のたびに呼ばれる。久しぶりに現れた相手には、覚えている割り当てを送り直す
    static func noteHello(id: String, prevSeen: Date?) {
        let pos = loadPos()
        guard pos[id] != nil else { return }
        let now = Date()
        if let prev = prevSeen, now.timeIntervalSince(prev) < 25 { return }
        if let last = lastAssign[id], now.timeIntervalSince(last) < 60 { return }
        let all = derive(rects: rects(pos: pos))
        sendAssign(to: id, links: all[id] ?? [])
    }
}

/// レイアウト編集のキャンバス。タイルをドラッグして並べ、辺がくっついた相手を隣にする。
/// スナップ有効時は、他のタイルの辺・中央線に、自分の辺・中心が吸着し、ガイド線を出す
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

    // MARK: 座標変換(配置座標は y 下向き、ビューは y 上向き)
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

    // MARK: 色の変更
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

    // MARK: ドラッグ
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

    // MARK: 描画
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
        let label = "未配置（ここからドラッグで配置、下の帯へ戻すと外れます）"
        let lattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (label as NSString).draw(at: NSPoint(x: 16, y: Double(trayHeight) - 22), withAttributes: lattrs)

        // スナップのガイド線
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
        let mcol = colorFromHex(machineColorHex(of: id))
        mcol.setStroke()
        path.lineWidth = (isSelf ? 3 : 2.5) + (dragging ? 1.5 : 0)
        path.stroke()
        // 右上の色チップ(クリックで色を変更)
        let chip = NSRect(x: viewRect.maxX - 21, y: viewRect.maxY - 21, width: 15, height: 15)
        let chipPath = NSBezierPath(ovalIn: chip)
        mcol.setFill()
        chipPath.fill()
        NSColor.white.setStroke()
        chipPath.lineWidth = 2
        chipPath.stroke()
        swatches[id] = chip
        let name = LayoutStore.name(of: id) + (isSelf ? "（自分）" : "")
        let s = LayoutStore.size(of: id)
        let sub = "\(Int(s.w))×\(Int(s.h))" + (online ? "" : "・応答なし")
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        let midY = Double(viewRect.midY)
        let nameRect = NSRect(x: viewRect.minX + 4, y: CGFloat(midY - 2), width: viewRect.width - 8, height: 16)
        (name as NSString).draw(in: nameRect, withAttributes: nameAttrs)
        let subRect = NSRect(x: viewRect.minX + 4, y: CGFloat(midY - 18), width: viewRect.width - 8, height: 13)
        (sub as NSString).draw(in: subRect, withAttributes: subAttrs)
    }
}

/// レイアウト編集ウィンドウ
final class LayoutWindowController: NSWindowController {
    private var canvas: LayoutCanvasView!

    convenience init() {
        self.init(window: nil)
        canvas = LayoutCanvasView(frame: NSRect(x: 0, y: 0, width: 680, height: 470))
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let snapBox = NSButton(checkboxWithTitle: "スナップ（辺・中央線に吸着）", target: self, action: #selector(toggleSnap(_:)))
        snapBox.state = canvas.snapEnabled ? .on : .off
        let hint = NSTextField(labelWithString: "辺がくっつくと隣になります。タイル右上の丸で、そのマシンの色を変更できます")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [snapBox, hint])
        bar.orientation = .horizontal
        bar.spacing = 16
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let root = NSStackView(views: [bar, canvas])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "レイアウト編集"
        window.contentView = root
        window.minSize = NSSize(width: 480, height: 400)
        self.window = window
    }

    @objc func toggleSnap(_ b: NSButton) {
        canvas.snapEnabled = b.state == .on
        UserDefaults.standard.set(canvas.snapEnabled, forKey: "layoutSnap")
    }
}

// MARK: - クリップボード共有

/// テキストだけを全ピアで共有する(上限 64KB、トグル式・既定オフ)。
/// 断片化して送り、経路は sendFast が選ぶ(Mac 同士は TCP、Windows へは UDP)。
/// 受けたテキストを自分のクリップボードに入れたら、その changeCount を覚えて
/// 送り返さない(ループ防止)。
final class ClipShare {
    static let shared = ClipShare()
    var enabled = UserDefaults.standard.bool(forKey: "clipShare")
    var onNote: ((String) -> Void)?

    private var lastChange = NSPasteboard.general.changeCount
    private var appliedChange = -1
    private var sendCounter = 0
    private var assemblies: [String: (total: Int, parts: [Int: String], first: Date)] = [:]
    private var timer: Timer?

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        let now = Date()
        assemblies = assemblies.filter { now.timeIntervalSince($0.value.first) < 10 }
        if !enabled { lastChange = pb.changeCount; return }
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if pb.changeCount == appliedChange { return }   // 自分が受けて入れたもの
        guard let s = pb.string(forType: .string), !s.isEmpty, s.utf8.count <= 65536 else { return }
        send(text: s)
    }

    private func send(text: String) {
        let b64 = Data(text.utf8).base64EncodedString()
        let chunkSize = 800
        let total = (b64.count + chunkSize - 1) / chunkSize
        sendCounter += 1
        let tid = "\(LinkNet.machineID)-\(sendCounter)"
        for peer in LinkNet.peers.keys {
            for i in 0..<total {
                let start = b64.index(b64.startIndex, offsetBy: i * chunkSize)
                let end = b64.index(start, offsetBy: min(chunkSize, b64.count - i * chunkSize))
                LinkNet.sendFast("clip \(peer) \(tid) \(i) \(total) \(b64[start..<end])")
            }
        }
        onNote?("クリップボード共有： テキストを送りました")
    }

    /// LinkNet から呼ばれる。args = [宛先, 転送ID, 番号, 総数, Base64断片]
    func receive(args: [String], from: String) {
        guard enabled, args.count == 5, args[0] == LinkNet.machineID,
              let idx = Int(args[2]), let total = Int(args[3]),
              total >= 1, total <= 200, idx >= 0, idx < total else { return }
        let key = "\(from)|\(args[1])"
        var asm = assemblies[key] ?? (total: total, parts: [:], first: Date())
        asm.parts[idx] = args[4]
        assemblies[key] = asm
        guard asm.parts.count == total else { return }
        assemblies[key] = nil
        let b64 = (0..<total).map { asm.parts[$0] ?? "" }.joined()
        guard let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8),
              !text.isEmpty, text.utf8.count <= 65536 else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        appliedChange = pb.changeCount
        lastChange = pb.changeCount
        onNote?("クリップボード共有： テキストを受け取りました")
    }
}

// MARK: - アプリ本体

/// メニューバー用の「指3本」アイコン(テンプレート画像)
/// メニューバー用の「ワ」(ワンマンカーソル)。丸ゴがあればそれ、無ければ太字で描く
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
    var clipItem: NSMenuItem!
    var loginItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateDefaultsIfNeeded()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = fingerIcon()
        let menu = NSMenu()
        enabledItem = NSMenuItem(title: "有効", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        remoteItem = NSMenuItem(title: "リモート操作モード（Moonlight 使用時も有効）", action: #selector(toggleRemote), keyEquivalent: "")
        remoteItem.target = self
        linkItem = NSMenuItem(title: "相方モード（ネットワークで合図を送受信）", action: #selector(toggleLink), keyEquivalent: "")
        linkItem.target = self
        cursorItem = NSMenuItem(title: "カーソル共有（端で相手に渡す）", action: #selector(toggleCursor), keyEquivalent: "")
        cursorItem.target = self
        clipItem = NSMenuItem(title: "クリップボード共有", action: #selector(toggleClip), keyEquivalent: "")
        clipItem.target = self
        let layoutItem = NSMenuItem(title: "レイアウトを編集…", action: #selector(openLayoutEditor), keyEquivalent: "")
        layoutItem.target = self
        tapItem = NSMenuItem(title: "キー送信をセッション方式にする", action: #selector(toggleTap), keyEquivalent: "")
        tapItem.target = self
        let moveParent = NSMenuItem(title: "画面移動の調整", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        let pushParent = NSMenuItem(title: "端の押し込み量", action: nil, keyEquivalent: "")
        let pushMenu = NSMenu()
        pushItems = []
        for px in [0, 10, 20, 40, 80] {
            let pi = NSMenuItem(title: px == 0 ? "なし（触れたら即）" : "\(px) px", action: #selector(pickPush(_:)), keyEquivalent: "")
            pi.target = self
            pi.tag = px
            pushMenu.addItem(pi)
            pushItems.append(pi)
        }
        pushParent.submenu = pushMenu
        let multParent = NSMenuItem(title: "移動の倍率", action: nil, keyEquivalent: "")
        let multMenu = NSMenu()
        multItems = []
        for m in [50, 75, 100, 125, 150, 200] {
            let mi = NSMenuItem(title: String(format: "%.2f 倍", Double(m) / 100), action: #selector(pickMult(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = m
            multMenu.addItem(mi)
            multItems.append(mi)
        }
        multParent.submenu = multMenu
        moveMenu.addItem(pushParent)
        moveMenu.addItem(multParent)
        moveParent.submenu = moveMenu
        lastItem = NSMenuItem(title: "最後の検出： なし", action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        mtItem = NSMenuItem(title: "トラックパッド： —", action: nil, keyEquivalent: "")
        mtItem.isEnabled = false
        statsItem = NSMenuItem(title: "受信： 0フレーム / 最大0本", action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        diagItem = NSMenuItem(title: "状態の詳細を表示", action: #selector(toggleDiag), keyEquivalent: "")
        diagItem.target = self
        let permItem = NSMenuItem(title: "アクセシビリティ許可を開く…", action: #selector(openPermSettings), keyEquivalent: "")
        permItem.target = self
        let inputItem = NSMenuItem(title: "入力監視の許可を開く…", action: #selector(openInputSettings), keyEquivalent: "")
        inputItem.target = self
        menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(linkItem); menu.addItem(cursorItem); menu.addItem(clipItem); menu.addItem(tapItem); menu.addItem(layoutItem); menu.addItem(moveParent); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(diagItem); menu.addItem(.separator())
        menu.addItem(permItem); menu.addItem(inputItem); menu.addItem(.separator())
        cursorShowItem = NSMenuItem(title: "カーソルを大きく表示", action: #selector(toggleCursorShow), keyEquivalent: "")
        cursorShowItem.target = self
        let shapeParent = NSMenuItem(title: "カーソルの形", action: nil, keyEquivalent: "")
        let shapeMenu = NSMenu()
        cursorShapeItems = []
        for (i, name) in ["矢印", "丸", "本物そっくり"].enumerated() {
            let si = NSMenuItem(title: name, action: #selector(pickCursorShape(_:)), keyEquivalent: "")
            si.target = self
            si.tag = i
            shapeMenu.addItem(si)
            cursorShapeItems.append(si)
        }
        shapeParent.submenu = shapeMenu
        let cursorSettingsItem = NSMenuItem(title: "カーソル表示の設定…", action: #selector(openCursorSettings), keyEquivalent: "")
        cursorSettingsItem.target = self
        loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(cursorShowItem); menu.addItem(shapeParent); menu.addItem(cursorSettingsItem); menu.addItem(loginItem); menu.addItem(.separator())
        menu.delegate = self
        menu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        applyDiagVisibility()
        refreshMenu()

        Engine.shared.onAction = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        Engine.shared.onStats = { [weak self] frames, maxFingers in
            self?.statsItem.title = "受信： \(frames)フレーム / 最大\(maxFingers)本"
        }
        CursorShare.shared.onStatus = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        if CursorShare.shared.enabled {
            CursorShare.shared.installTap()
            CursorShare.shared.requestInputAccessIfNeeded()
        }

        // キーを送るにはアクセシビリティ許可が要る
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            alert("アクセシビリティ許可が必要です",
                  "スワイプで Finder にキーを送るため、システム設定 → プライバシーとセキュリティ → アクセシビリティ で OneManCursor を許可してください。許可したら OneManCursor を再起動してください。")
        }

        LinkNet.startReceiver()
        LinkNet.startHello()
        LinkNet.startTCP()
        ClipShare.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        ClipShare.shared.start()

        cursorOverlay.start()
        refreshCursorMenu()

        let devices = Multitouch.start()
        mtItem.title = devices > 0 ? "トラックパッド： 接続OK（\(devices)台）" : "トラックパッド： 接続失敗"
        if devices == 0 {
            alert("トラックパッドを読み込めませんでした",
                  "MultitouchSupport を開くか、トラックパッドの検出に失敗しました。この Mac では試作方式が使えない可能性があります。")
        }
    }

    /// 旧アプリ(FinderSwipe と AlwaysCursor)の設定を引き継ぐ(初回だけ)。
    /// machineID を引き継がないと、他マシンのレイアウト設定と合わなくなるので重要
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
        clipItem.state = ClipShare.shared.enabled ? .on : .off
        tapItem.state = Engine.shared.keyTapSession ? .on : .off
        diagItem.state = UserDefaults.standard.bool(forKey: "showDiag") ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for it in pushItems { it.state = it.tag == CursorShare.pushPx ? .on : .off }
        for it in multItems { it.state = it.tag == Int((CursorShare.moveMult * 100).rounded()) ? .on : .off }
    }

    var flashRestore: DispatchWorkItem?

    /// 検知した瞬間に、メニューバーのアイコンを一瞬薄くして知らせる
    func flashIcon() {
        guard let button = item.button else { return }
        flashRestore?.cancel()
        button.alphaValue = 0.25
        let work = DispatchWorkItem { [weak self] in self?.item.button?.alphaValue = 1.0 }
        flashRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    @objc func toggleEnabled() {
        Engine.shared.enabled.toggle()
        UserDefaults.standard.set(Engine.shared.enabled, forKey: "enabled")
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
        if menu == item.menu { refreshCursorMenu() }
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
            alert("ログイン項目を変更できませんでした", error.localizedDescription)
        }
        refreshMenu()
    }

    @objc func toggleClip() {
        ClipShare.shared.enabled.toggle()
        UserDefaults.standard.set(ClipShare.shared.enabled, forKey: "clipShare")
        refreshMenu()
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

    /// 最後の検出・トラックパッド・受信数の3行は診断用。普段は隠しておけるようにする
    private func applyDiagVisibility() {
        let v = UserDefaults.standard.bool(forKey: "showDiag")
        lastItem.isHidden = !v
        mtItem.isHidden = !v
        statsItem.isHidden = !v
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
