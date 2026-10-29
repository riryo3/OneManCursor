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
        udpSend(magic + "\(machineID) 0 hello \(name)")
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
            let name = parts.dropFirst(3).joined(separator: " ")
            peers[String(parts[0])] = (name.isEmpty ? "Mac" : name, ip, Date())
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
}

/// カーソル共有の試作。
/// 起点の Mac はイベントタップでマウスとキーを横取りし、宛先付きの合図に変えて送る。
/// 受けた Mac は自分の画面で再現し、さらに隣がいる端を越えたら次の相手へ中継する。
/// Esc は非常口: 起点ではセッション終了、参加者では全体リセットを合図する。
final class CursorShare {
    static let shared = CursorShare()
    var enabled = UserDefaults.standard.bool(forKey: "cursorShare")
    var onStatus: ((String) -> Void)?

    /// 方向 → 相方のマシンID
    private(set) var neighbors: [PartnerDir: String] = [:]

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
        for dir in [PartnerDir.right, .left, .up, .down] {
            if let id = UserDefaults.standard.string(forKey: "neighbor_" + dir.rawValue) {
                neighbors[dir] = id
            }
        }
    }

    func setNeighbor(_ dir: PartnerDir, id: String?) {
        neighbors[dir] = id
        let key = "neighbor_" + dir.rawValue
        if let id = id {
            UserDefaults.standard.set(id, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func dir(ofPeer id: String) -> PartnerDir? {
        neighbors.first { $0.value == id }?.key
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
            guard let next = neighbors[dir] else { continue }
            if push > 0 {
                edgePush[dir, default: 0] += max(0, outward)
                if edgePush[dir, default: 0] < push { continue }
            }
            sending = true
            awayTo = next
            edgePush.removeAll()
            multAccX = 0; multAccY = 0
            for _ in 0..<3 { LinkNet.sendFast("enter \(next) \(ratio) \(dir.rawValue)") }
            hideCursor()
            startPinning(at: loc)
            status("カーソル共有： \(peerName(next)) に渡しました")
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
            // 自分が起点でも、カーソルが手元に戻っている状態なら受け取れる(セッションは相手に譲る)。
            // ここで弾くと「一度送った側には二度と戻せない」非対称な詰まりになる
            guard awayTo == nil, !holding, forwardTo == nil, rest.count >= 1 else { return }
            sending = false
            holding = true
            cameFrom = from
            let ratio = Double(rest[0]) ?? 0.5
            if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: ratio) }
            warp()
            status("カーソル共有： \(peerName(from)) から受け取りました")
        case "leave":
            guard rest.count >= 1 else { return }
            let ratio = Double(rest[0]) ?? 0.5
            if awayTo == from {
                // 起点にカーソルが戻ってきた(セッション自体は継続)
                awayTo = nil
                showCursor()
                stopPinning()
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: ratio); warp() }
                status("カーソル共有： 手元に戻りました")
            } else if forwardTo == from {
                // 中継していた先から戻ってきた → 自分が保持者になる(cameFrom は元の相手のまま)
                forwardTo = nil
                holding = true
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: ratio); warp() }
                status("カーソル共有： 戻ってきました")
            }
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
        guard let next = neighbors[dir] else { return false }
        if next == cameFrom {
            LinkNet.sendFast("leave \(next) \(ratio)")
            holding = false
            cameFrom = nil
            status("カーソル共有： 手元に返しました")
        } else {
            LinkNet.sendFast("enter \(next) \(ratio) \(dir.rawValue)")
            forwardTo = next
            holding = false
            status("カーソル共有： \(peerName(next)) へ渡しました")
        }
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
    var layoutMenu: NSMenu!
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
        let layoutParent = NSMenuItem(title: "レイアウト（相方の配置）", action: nil, keyEquivalent: "")
        layoutMenu = NSMenu()
        layoutMenu.delegate = self
        layoutParent.submenu = layoutMenu
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
        menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(linkItem); menu.addItem(cursorItem); menu.addItem(clipItem); menu.addItem(tapItem); menu.addItem(layoutParent); menu.addItem(moveParent); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(diagItem); menu.addItem(.separator())
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

    /// レイアウトメニューは開くたびに、発見済みの相方から作り直す
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == item.menu { refreshCursorMenu(); return }
        guard menu == layoutMenu else { return }
        menu.removeAllItems()
        let me = NSMenuItem(title: "この Mac： \(Host.current().localizedName ?? "Mac")（ID: \(LinkNet.machineID)）", action: nil, keyEquivalent: "")
        me.isEnabled = false
        menu.addItem(me)
        menu.addItem(.separator())
        // 最近(30秒以内)に合図があった相手だけを出す。古い記録が残ると同じ相手が二つに見えるため
        let peers = LinkNet.peers.filter { Date().timeIntervalSince($0.value.seen) < 30 }.sorted { $0.value.name < $1.value.name }
        if peers.isEmpty {
            let none = NSMenuItem(title: "相方が見つかっていません（相手でもアプリを起動してください）", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for (id, info) in peers {
            let parent = NSMenuItem(title: "\(info.name)（ID: \(id)）", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (label, raw) in [("右に置く", "right"), ("左に置く", "left"), ("上に置く", "up"), ("下に置く", "down"), ("外す", "none")] {
                let it = NSMenuItem(title: label, action: #selector(setNeighborFromMenu(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = "\(raw)|\(id)"
                if raw == "none" {
                    it.state = CursorShare.shared.dir(ofPeer: id) == nil ? .on : .off
                } else if let d = PartnerDir(rawValue: raw) {
                    it.state = CursorShare.shared.neighbors[d] == id ? .on : .off
                }
                sub.addItem(it)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
    }

    @objc func setNeighborFromMenu(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let parts = s.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return }
        let raw = String(parts[0]), id = String(parts[1])
        // 同じ相手が別の方向にいたら先に外す(相手は1方向にだけ置く)
        if let old = CursorShare.shared.dir(ofPeer: id) {
            CursorShare.shared.setNeighbor(old, id: nil)
        }
        if raw != "none", let d = PartnerDir(rawValue: raw) {
            CursorShare.shared.setNeighbor(d, id: id)
        }
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
