import Cocoa
import ApplicationServices
import IOKit
import ServiceManagement
import UniformTypeIdentifiers
import ScreenCaptureKit

// OneManCursor: Finder でスワイプ操作するための常駐アプリ(試作)
// - 2本指の横フリック → 戻る(⌘[) / 進む(⌘])
// - 3本指の下スワイプ → 上の階層(⌘↑)、3本指の上スワイプ → 開く(⌘O)
// Finder が最前面のときだけ効く。指の動きは MultitouchSupport(Private)で直接読む。

/// ビルド番号(版の確認用。機能を変えたら上げる)
let buildTag = "Build 20261031-68"

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

    /// リモート操作アプリが最前面かどうか。キー入力を向こうのマシンへ転送するアプリなら
    /// Moonlight でなくても同じ仕組みでスワイプが効くので、代表的なアプリを対象にしている
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

    // 診断用: コールバックが来ているか、指の数が読めているか
    private(set) var frames = 0
    private(set) var maxFingers = 0
    private var lastStatsPush: Double = 0
    private var windowFrames = 0   // 監視用: 直近の集計区間のフレーム数
    private var windowMax = 0      // 監視用: 直近の集計区間の最大の指の数

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

    /// 監視用: 前回呼ばれてからの (フレーム数, 最大の指の数) を返してリセットする
    func takeWindowStats() -> (Int, Int) {
        defer { windowFrames = 0; windowMax = 0 }
        return (windowFrames, windowMax)
    }

    private var session = false
    private var lockedCount = 0       // セッション中に確認した最大の指の数(2 か 3)
    private var lockStableSince: Double = 0   // 本数が最後に増えた時刻(遅れて触れる指を待つため)
    private var startX: Float = 0, startY: Float = 0
    private var startT: Double = 0
    private var fired = false
    private var lastDx: Float = 0, lastDy: Float = 0   // 診断用: 最後に見た移動量
    private var horizLatch = false   // ブラウザ向け押し出し: 横意図を一度掴んだら保持する

    // しきい値(正規化座標 0...1 に対する割合)
    private let flickMin: Float = 0.20     // 2本指フリックの最小移動量
    private let vertMin: Float = 0.20      // 3本指の最小移動量
    private let flickMaxTime = 0.6         // 2本指はこの時間内に大きく動いたものだけ拾う
    private let graceTime = 0.09           // 3本目が遅れて触れるのを待つ時間

    func handle(_ fingers: [Finger], timestamp: Double) {
        let downs = fingers.filter { $0.state == 3 || $0.state == 4 }
        if downs.isEmpty {
            if session && !fired && lockedCount >= 3 {
                NetLog.shared.log("ジェスチャ不成立: 指\(lockedCount)本 dy=\(lastDy) dx=\(lastDx)")
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
            // 相手がブラウザのときは、横への「押し出し」も戻る/進むとして拾う
            // (Chrome のスワイプはフリックより遅く長いので、通常のフリック判定では拾えない)。
            // 指の動きそのもので判定するので、指を離した後の反動(惰性スクロール)は混ざらない
            if CursorShare.shared.sessionActiveAway, CursorShare.shared.remoteIsBrowser {
                if abs(dx) >= 0.05, abs(dx) >= 1.5 * abs(dy) { horizLatch = true }
                if horizLatch { CursorShare.shared.engageScrollSuppress() }
                if horizLatch, abs(dx) >= 0.15, abs(dx) >= 1.5 * abs(dy), elapsed <= 1.5 {
                    fire(dx > 0 ? .back : .forward)
                    return
                }
            }
            // 横フリック: 右へ = 戻る、左へ = 進む(Safari と同じ向き)
            guard elapsed >= graceTime, elapsed <= flickMaxTime else { return }
            if abs(dx) >= flickMin, abs(dx) >= 2 * abs(dy) {
                fire(dx > 0 ? .back : .forward)
            }
        } else if lockedCount == 3 {
            // 縦: 下へ = 上の階層、上へ = 開く
            // 4本目が遅れて触れることがあるため、本数が安定するまでは発火しない。
            // 安定を待たないと、4本指スワイプを3本指と誤認して横取りしてしまう
            if timestamp - lockStableSince >= graceTime, abs(dy) >= vertMin, abs(dy) >= 2 * abs(dx) {
                let front = NSWorkspace.shared.frontmostApplication
                let finderContext = front?.bundleIdentifier == "com.apple.finder"
                    || (remoteMode && Self.isRemoteApp(front))
                    || CursorShare.shared.sessionActiveAway
                if enabled && !finderContext {
                    // Finder 操作として効かない場面の3本指縦スワイプは切り替え連動に回す
                    // (4本指のつもりで1本が軽く触れていた場合の受け皿。今は無反応な入力)
                    fired = true
                    let up = dy > 0
                    DispatchQueue.main.async { SwitchSync.shared.noteGesture(up: up) }
                } else {
                    fire(dy > 0 ? .open : .parent)
                }
            }
        } else if lockedCount >= 4 {
            // 4本指の縦スワイプは Mission Control / Exposé のジェスチャ(切り替え連動の検知)
            if abs(dy) >= vertMin, abs(dy) >= 2 * abs(dx) {
                fired = true
                let up = dy > 0
                DispatchQueue.main.async { SwitchSync.shared.noteGesture(up: up) }
            }
        }
    }

    private func fire(_ action: SwipeAction) {
        fired = true
        // 送ってよい場面: Finder が最前面のとき。
        // リモート操作モードでは Moonlight が最前面のときも送る(キーは Moonlight 経由で相手側に届く)
        let front = NSWorkspace.shared.frontmostApplication
        let isFinder = front?.bundleIdentifier == "com.apple.finder"
        let isRemote = remoteMode && Self.isRemoteApp(front)
        var note = ""
        if !enabled {
            note = "（無効中）"
        } else if CursorShare.shared.sessionActiveAway {
            // カーソル共有で相手を操作中なら、スワイプもキー入力として相手に送る。
            // ただし相手のアプリに合わない動作は送らない(Chrome に ⌘O を送ると
            // ファイルを開くダイアログが出てしまう、など)
            if CursorShare.shared.swipeAllowedRemotely(action) {
                CursorShare.shared.forwardActionKey(for: action)
                note = "（カーソル共有で送信）"
            } else {
                note = "（相手のアプリのため送信なし）"
            }
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
        NetLog.shared.log("スワイプ受信 \(wire): Finder最前面=\(front?.bundleIdentifier == "com.apple.finder")")
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
        if !body.hasPrefix("mv ") { NetLog.shared.log("送信 " + body) }
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
            CursorShare.shared.resetFromSignal()
            return
        }
        if SwipeAction.fromWire(kind) != nil {
            // スワイプの合図: 複数回・複数経路で届く同じものは1回だけ実行する
            let now = Date().timeIntervalSince1970
            if let seen = seenSeqs[seq], now - seen < 2 { return }
            seenSeqs[seq] = now
            seenSeqs = seenSeqs.filter { now - $0.value < 10 }
            NetLog.shared.log("受信 \(kind) from=\(parts[0]) → スワイプ処理")
            Engine.shared.receiveLink(kind)
        } else {
            // カーソル共有の合図: UDP では3回送られてくるので、同じ連番は1回だけ処理する
            let dupKey = "\(parts[0])-\(seq)"
            let nowFast = Date().timeIntervalSince1970
            if let seen = seenFast[dupKey], nowFast - seen < 2 { return }
            seenFast[dupKey] = nowFast
            seenFast = seenFast.filter { nowFast - $0.value < 10 }
            if kind != "mv" && kind != "dn" && kind != "up" && kind != "sc" && kind != "kd" && kind != "ku" && kind != "fl" { NetLog.shared.log("受信 \(kind) from=\(parts[0]) → 共有処理") }
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
    private(set) var cursorAtID: String?   // カーソルが今いるマシン(全台で共有する現在地)
    private var vx: Double = 0, vy: Double = 0

    // 画面移動の調整(メニュー「画面移動の調整」で変更)
    /// 端の押し込み量(px)。0 = 端に触れたら即移動
    /// 単独モード: カーソルを他のマシンへ渡さず、届いたカーソルも送り返す(画面端で迷子にしないため)。端末ごとに設定する
    var soloMode: Bool {
        get { UserDefaults.standard.bool(forKey: "soloMode") }
        set { UserDefaults.standard.set(newValue, forKey: "soloMode") }
    }

    /// 単独モードに入る瞬間の後始末: 持っているカーソルは持ち主へ返し、渡しているセッションは畳む
    func enforceSolo() {
        if holding, let from = cameFrom {
            LinkNet.sendFast("leave \(from) 0.5")
            holding = false
            cameFrom = nil
            EdgeGlow.shared.hide()
            status("単独モード： カーソルを返しました")
        } else if sending || forwardTo != nil {
            LinkNet.sendReset()
            resetSession()
            status("単独モード： セッションを終了しました")
        }
    }

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
        remoteAppID = nil
        remoteAppPeer = nil
        showCursor()
        stopPinning()
        EdgeGlow.shared.hide()
    }

    /// 非常口(⌘Esc)を押したマシン専用: 見失ったカーソルを画面の真ん中へ連れてくる。
    /// 合図でリセットされただけの他マシンでは動かない(そちらの利用者を驚かせないため)
    func centerCursor() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
        let primaryH = screens[0].frame.height
        // NSScreen は左下原点、Quartz は左上原点なので主画面の高さで反転する
        let center = CGPoint(x: screen.frame.midX, y: primaryH - screen.frame.midY)
        CGWarpMouseCursorPosition(center)
        // ワープだけではイベント上の位置がずれるので、実イベントも1発流す
        if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
            Self.markSynthetic(mv)
            mv.post(tap: .cghidEventTap)
        }
        NetLog.shared.log("⌘Esc: カーソルを画面中央へ移動")
    }

    /// 合図でリセットされたときの処理。セッション中だったマシンはカーソルも真ん中へ
    /// 戻す(言うことを聞かなくなったマシンを、遠くの ⌘Esc で助けるため)。
    /// セッション外だったマシンでは状態を畳むだけ(驚かせない)
    func resetFromSignal() {
        let wasInSession = sending || holding || forwardTo != nil
        resetSession()
        if wasInSession { centerCursor() }
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

    /// 合成イベントに目印を付ける(自分のタップで飲まないため)
    static func markSynthetic(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
    }

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
        if enabled, awayTo == nil, !holding, forwardTo == nil,
           type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            updateGlowAtHome(event.location)
        }
        // 非常口は ⌘Esc。Esc 単体はよく使うキーなので、普通のキーとして相手へ送る
        let isEsc = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 && event.flags.contains(.maskCommand)
        // 切り替え画面の連動: 手元で Ctrl+↑ を押したら「一覧を開いた」、切り替え中の Esc は「確定」
        if type == .keyDown, awayTo == nil, !holding, forwardTo == nil {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == 126, event.flags.contains(.maskControl), !event.flags.contains(.maskCommand) {
                SwitchSync.shared.noteOpenKey()
            } else if kc == 99, !event.flags.contains(.maskCommand) {
                // MCキー(F3): 標準キーとして届く場合
                SwitchSync.shared.noteOpenKey()
            } else if kc == 53, !event.flags.contains(.maskCommand) {
                SwitchSync.shared.noteLocalEsc()
            }
        }
        // 検索の連動: 手元で ⌘+Space を押したら起点になり、打鍵を全端末へ送る
        if awayTo == nil, !holding, forwardTo == nil {
            if type == .keyDown {
                let kc = event.getIntegerValueField(.keyboardEventKeycode)
                if kc == 49, event.flags.contains(.maskCommand) {
                    if SearchSync.shared.origin { SearchSync.shared.noteLocalEnd() } else { SearchSync.shared.noteLocalOpen() }
                } else if SearchSync.shared.origin, kc == 53 {
                    // Esc は IME の取消と見分けるため、SearchSync 側で様子見して判断する
                    SearchSync.shared.forwardKey(keycode: kc)
                } else if SearchSync.shared.origin {
                    // 打鍵はそのまま全端末へ転送する(Enter を含む)
                    SearchSync.shared.forwardTypedKey(type: type, event: event)
                }
            } else if SearchSync.shared.origin, type == .keyUp || type == .flagsChanged {
                SearchSync.shared.forwardTypedKey(type: type, event: event)
            } else if SearchSync.shared.origin, type == .leftMouseDown || type == .rightMouseDown {
                SearchSync.shared.noteLocalEnd()
            }
        }

        // 他機起点のセッションに参加中(保持者・中継者): 物理マウスは位置がずれるので飲む。⌘Esc で全体リセット
        if holding || forwardTo != nil {
            if isEsc {
                LinkNet.sendReset()
                resetSession()
                centerCursor()
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
                if isEsc { resetSession(); centerCursor() }
                if isMove(type), checkEdges(event) { return nil }
                return Unmanaged.passUnretained(event)
            }
            // カーソルは相手側: ⌘Esc で終了、それ以外は合図に変えて飲む
            if isEsc {
                LinkNet.sendReset()
                resetSession()
                centerCursor()
                status("カーソル共有： 終了しました")
                return nil
            }
            forwardPhysical(type: type, event: event, to: awayTo!)
            return nil
        }

        // 待機中: 端に触れたらセッション開始。⌘Esc は「カーソル探し」として真ん中へ
        if isEsc { centerCursor() }
        if isMove(type), checkEdges(event) { return nil }
        return Unmanaged.passUnretained(event)
    }

    /// 起点が知っている「相手の最前面アプリ」(保持者からの app 報告。未報告なら nil)
    private(set) var remoteAppID: String?
    private(set) var remoteAppPeer: String?

    private var appObserver: NSObjectProtocol?

    /// 保持者として、自分の最前面アプリを起点へ知らせる(共有中スワイプのアプリ別ゲート用)
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

    /// ブラウザとみなすアプリ(共有中のスワイプ振り分け・横スワイプ判定用)
    private static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// 相手の最前面がブラウザか(app 報告ベース)
    var remoteIsBrowser: Bool {
        guard let bid = remoteAppID, remoteAppPeer == awayTo else { return false }
        return Self.browserIDs.contains(bid)
    }

    // ブラウザ向け横スワイプ中のスクロール転送抑制(Engine から操作する)
    private var scrollSuppressEngaged = false
    private var scrollSuppressUntil = 0.0
    func engageScrollSuppress() {
        scrollSuppressEngaged = true
        scrollSuppressUntil = Date().timeIntervalSince1970 + 0.5
    }
    func releaseScrollSuppress() {
        // 指が離れたら、反動(惰性スクロール)を食べきるまで少し延長してから解ける
        if scrollSuppressEngaged { scrollSuppressUntil = Date().timeIntervalSince1970 + 1.2 }
    }
    func clearScrollSuppress() { scrollSuppressEngaged = false; scrollSuppressUntil = 0 }
    var scrollSuppressed: Bool {
        if scrollSuppressEngaged && Date().timeIntervalSince1970 > scrollSuppressUntil { scrollSuppressEngaged = false }
        return scrollSuppressEngaged
    }

    /// 共有中のスワイプを相手へ送ってよいか(相手のアプリで判断する)
    func swipeAllowedRemotely(_ action: SwipeAction) -> Bool {
        guard let bid = remoteAppID, remoteAppPeer == awayTo else { return true }
        if bid == "com.apple.finder" { return true }
        if Self.browserIDs.contains(bid) { return action == .back || action == .forward }
        return false
    }

    /// 自分が起点で、カーソルが相手側にある状態か
    var sessionActiveAway: Bool { sending && awayTo != nil }

    /// 共有セッションのどの役割でもあるか(起点・保持・中継)
    var anySessionActive: Bool { sending || holding || forwardTo != nil }

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
        if soloMode { EdgeGlow.shared.hide(); return }
        let b = allBounds
        let spots: [(PartnerDir, Double, Double)] = [
            (.right, Double(b.maxX) - Double(loc.x), (Double(loc.y) - Double(b.minY)) / Double(b.height)),
            (.left, Double(loc.x) - Double(b.minX), (Double(loc.y) - Double(b.minY)) / Double(b.height)),
            (.down, Double(b.maxY) - Double(loc.y), (Double(loc.x) - Double(b.minX)) / Double(b.width)),
            (.up, Double(loc.y) - Double(b.minY), (Double(loc.x) - Double(b.minX)) / Double(b.width)),
        ]
        // いずれかの移動先(リンクのある辺)に近づいたら、移動先を全部光らせる
        let near = spots.contains { (dir, dist, _) in dist <= 56 && links.contains { $0.dir == dir } }
        if near && !links.isEmpty {
            EdgeGlow.shared.show(segments: links.map { (dir: $0.dir, link: $0) })
        } else {
            EdgeGlow.shared.hide()
        }
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
        // いずれかの移動先(リンクのある辺)に近づいたら、移動先を全部光らせる
        let near = spots.contains { (dir, dist, _) in dist <= 56 && links.contains { $0.dir == dir } }
        if near && !links.isEmpty {
            EdgeGlow.shared.show(segments: links.map { (dir: $0.dir, link: $0) })
        } else {
            EdgeGlow.shared.hide()
        }
    }

    /// 端に触れていたら相手に渡す。渡したら true
    /// 押し込み量が設定されているときは、端に張り付いたまま外向きに押し込んだ
    /// 合計がその量に達するまで渡さない(端でのバタつき防止にもなる)
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
            // 渡す位置は「共有辺の中の割合」に正規化する(ずらした配置でも位置が合うように)
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
            // ブラウザ向け横スワイプのジェスチャ中は、そのスクロール自体を相手へ送らない
            // (相手で横スクロールとして暴れるうえ、指を離した後の反動まで届いてしまうため)
            if scrollSuppressed { return }
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
                sendAtSelf()
                return
            }
            if soloMode {
                // 単独モード: 受け取らず、そのまま送り返す(送り手は「手元に戻ってきた」として処理する)
                LinkNet.sendFast("leave \(from) \(seg)")
                status("単独モード： \(peerName(from)) からのカーソルを返送しました")
                return
            }
            // 自分が起点でも、カーソルが手元に戻っている状態なら受け取れる(セッションは相手に譲る)。
            // ここで弾くと「一度送った側には二度と戻せない」非対称な詰まりになる
            guard awayTo == nil, !holding, forwardTo == nil else { return }
            sending = false
            holding = true
            cameFrom = from
            sendAtSelf()
            reportFrontApp()
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
                sendAtSelf()
            } else if forwardTo == from {
                // 中継していた先から戻ってきた → 自分が保持者になる(cameFrom は元の相手のまま)
                forwardTo = nil
                holding = true
                if let d = dir(ofPeer: from) { positionAtEdge(d, ratio: entryRatio(forPeer: from, seg: seg)); warp() }
                status("カーソル共有： 戻ってきました")
                sendAtSelf()
                reportFrontApp()
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
        case "at":
            if let holder = rest.first { cursorAtID = holder }
        case "app":
            if let bid = rest.first { remoteAppID = bid; remoteAppPeer = from }
        case "mother":
            UserDefaults.standard.set(from, forKey: "mothershipID")
            status("母艦は \(peerName(from)) になりました")
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
                // 検索の連動: 検索を開いている間に届いた打鍵は、検索への入力として再現する
                SearchSync.shared.applyRemoteKey(kind: kind, args: rest)
            } else if (kind == "kd" || kind == "ku" || kind == "fl"), SearchSync.shared.receiving {
                if kind == "kd" { NetLog.shared.log("検索連動: セッション中のため打鍵を適用できません") }
            } else if holding {
                apply(kind, args: rest)
            } else if let fwd = forwardTo {
                // 中継: 宛先を次の相手に書き換えてそのまま送る
                LinkNet.sendFast("\(kind) \(fwd) " + rest.joined(separator: " "))
            }
        default:
            break
        }
    }

    /// カーソルの現在地を全マシンへ知らせる(自分が保持者になったとき)
    private func sendAtSelf() {
        cursorAtID = LinkNet.machineID
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("at \(pid) \(LinkNet.machineID)")
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
            if kind == "fl" || code == 126 || code == 99 {
                NetLog.shared.log("キー適用: \(kind) code=\(code) flags=\(flagsRaw)")
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
    fileprivate var segs: [(dir: PartnerDir, color: NSColor, start: Double, end: Double)] = []

    /// 移動できる区間を全部同時に光らせる
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

    /// 必ずメインキュー経由で実行する。手元経路はイベントタップ(メインスレッド)から
    /// 呼ばれるため即実行すると、保持中経路(受信キュー→メインキュー)と実行文脈が
    /// 食い違い、表示が不安定になる疑いがあるため、経路を揃える
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
        // 移動できる区間だけを、それぞれの行き先の色で光らせる(輪郭全体を一番近い入り口の色で光らせることはしない)
        // 行き先の区間を強く(影でぼかす)。区間の両端には余白を空け、隣同士の色が混ざらないようにする
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
        // 接合部の隙間: 複数のマシンが集まる角(T字・十字の接合点)では、その点を共有する
        // リンクの端を両側へ少し(自分の辺の2%)ずらして「渡れない帯」を作る。
        // 角の取り合いでカーソルが行方不明になるのを防ぐため
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

    /// 配置を保存し、自分のリンクへ反映し、他の全マシンへ割り当てを送る
    static func apply(pos: [String: (x: Double, y: Double)]) {
        savePos(pos)
        // 母艦が決まっているときは、母艦以外は配布しない(古い配置での上書き事故を防ぐ)
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
        // 母艦が決まっているときは、母艦以外は送り直さない。自分が母艦なら母艦であることも伝える
        if let mid = UserDefaults.standard.string(forKey: "mothershipID"), mid != LinkNet.machineID { return }
        if UserDefaults.standard.string(forKey: "mothershipID") == LinkNet.machineID {
            LinkNet.sendFast("mother \(id)")
        }
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
        // 画面のサムネイルが届いていれば、タイル内に表示する(30秒以内のものだけ)
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
        if freshThumb != nil {
            // サムネイルの上では文字が読みにくいので、帯を敷く
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

/// 画面確認: 自分のマシンの色で画面全体を薄く光らせる(レイアウト編集の「画面で確認」用)
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

/// レイアウト編集ウィンドウ

// MARK: - 画面のサムネイル

/// レイアウト編集のタイルに、各マシンの画面の縮小画像を出すための送受信。
/// 編集画面を開いている端末が threq を送り、受けた側が自分の画面を撮って
/// JPEG を細切れ(thimg)にして返す。遅延は気にしない(数秒単位でよい)前提
final class ThumbShare {
    static let shared = ThumbShare()
    private(set) var images: [String: (img: NSImage, at: Date)] = [:]
    private var assembly: [String: (tid: String, parts: [Int: String], total: Int)] = [:]
    private var lastCaptureAt = Date.distantPast
    private var capturing = false

    /// threq を受けた: 自分の画面を撮って、頼んだ相手へ送る
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

    /// 自分のサムネイル(自分のタイル用)。送らずに手元へしまう
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

    /// 自分の画面を幅320pxの JPEG にする(画面収録の許可が無いと失敗する)
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
                NetLog.shared.log("サムネ撮影に失敗: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    /// thimg を受けた: 断片を集めて1枚にする(組み立てはメインスレッドで)
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
        let snapBox = NSButton(checkboxWithTitle: "スナップ（辺・中央線に吸着）", target: self, action: #selector(toggleSnap(_:)))
        let idButton = NSButton(title: "画面で確認", target: self, action: #selector(identifyScreens))
        idButton.bezelStyle = .rounded
        let motherButton = NSButton(title: "この端末を母艦にする", target: self, action: #selector(becomeMothership))
        motherButton.bezelStyle = .rounded
        snapBox.state = canvas.snapEnabled ? .on : .off
        let hint = NSTextField(labelWithString: "辺がくっつくと隣になります。タイル右上の丸で、そのマシンの色を変更できます")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        // ボタン類と説明文を同じ行に入れると幅が足りずボタンが消えることがあるため、2段にする
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

    /// 編集画面を開いている間だけ、各マシンの画面サムネイルを集める
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

    /// 全端末の画面を、それぞれの色で光らせる(どのタイルがどの実機か確かめる)
    @objc func identifyScreens() {
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("identify \(pid)")
        }
        IdentifyGlow.shared.showSelf()
    }

    /// この端末を母艦(レイアウトの配布元)にする。以後は母艦以外は割り当てを配らない
    @objc func becomeMothership() {
        UserDefaults.standard.set(LinkNet.machineID, forKey: "mothershipID")
        for pid in LinkNet.peers.keys where pid != LinkNet.machineID {
            LinkNet.sendFast("mother \(pid)")
        }
        LayoutStore.apply(pos: LayoutStore.loadPos())
        window?.title = mothershipTitle()
    }

    private func mothershipTitle() -> String {
        guard let mid = UserDefaults.standard.string(forKey: "mothershipID") else { return "レイアウト編集" }
        if mid == LinkNet.machineID { return "レイアウト編集（この端末が母艦）" }
        return "レイアウト編集（母艦: \(LayoutStore.name(of: mid)))"
    }
}

// MARK: - ダイアログへのスナップ

/// Windows の「既定のボタンにポインターを移動する」にあたる機能。
/// ダイアログ(シート含む)が現れたら、その既定ボタンの真ん中へカーソルを運ぶ。
/// 最前面アプリのウィンドウ生成を Accessibility で監視する
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
        // シートは生成通知が来ないので、最前面アプリを定期的に見回る
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
        // システム系のダイアログ(SecurityAgent など)は最前面アプリとして現れないことが
        // 多いので、2秒に1回、起動中の全アプリも見回る
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

    /// 既存のウィンドウを走査する(アプリ切替時など、既に出ているダイアログ用)
    func scan(appElement: AXUIElement) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        for w in windows {
            inspect(window: w)
            // シートはウィンドウの子(AXSheet)としてぶら下がるので、子も見る
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

    /// ウィンドウの識別子(同じダイアログへ二度運ばないため)
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
        // ダイアログでないものは記録して二度見ない。ダイアログなのにボタンがまだ
        // 用意できていない場合は記録せず、次の見回りでもう一度見る
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
        // ワープだけだと「見た目の位置」しか変わらず、クリックが前の位置に落ちることがある。
        // 実イベント(mouseMoved)を1発流して、イベントとしてのマウス位置も一致させる
        if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) {
            CursorShare.markSynthetic(mv)
            mv.post(tap: .cghidEventTap)
        }
        seenWindows.insert(key)
        if seenWindows.count > 200 { seenWindows.removeAll() }
        NetLog.shared.log("ダイアログ: 既定ボタンへ移動")
        onNote?("ダイアログの既定ボタンへ移動しました")
    }

    /// ダイアログ本体か、シート(親がウィンドウ)なら true
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

/// 切り替え画面の連動: どこかの端末でウィンドウ選択を確定したら、他の端末で
/// 開いている Mission Control / タスクビューを Esc で閉じる
func switchKeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // MCキーなど特殊キー(システム定義イベント)の足跡をログに残すための聞き専用タップ
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {
        let d1 = ns.data1
        // subtype=7 はクリックのたびにも出るイベントで、F3 の署名ではなかった(2026-10-30 実測で判明)。
        // 検知には使わず、data1/data2 の全量をログに残して署名の特定を続ける
        NetLog.shared.log("システムキー: subtype=\(ns.subtype.rawValue) data1=0x\(String(d1, radix: 16)) data2=0x\(String(ns.data2, radix: 16))")
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
    private var lastFlagChangeAt = Date.distantPast   // 診断用: フラグが最後に変わった時刻
    var onNote: ((String) -> Void)?

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
            self?.noteActivation(app: app)
        }
        // MCキーなどの特殊キーの足跡を取る(聞き専用タップ)
        let sysMask = CGEventMask(1) << 14
        if let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: sysMask, callback: switchKeyCallback, userInfo: nil) {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// 一覧が開いている間にアプリが切り替わった = そこで確定した
    private func noteActivation(app: String) {
        if switching {
            NetLog.shared.log("アプリ切替を検知: \(app)")
            guard enabled else { return }
            decide(reason: "アプリ切替(\(app))")
        } else if Date().timeIntervalSince(lastFlagChangeAt) < 90 {
            // 確定しなかったアプリ切替も、連動の直後しばらくは記録する(切り分け用)
            NetLog.shared.log("アプリ切替を検知: \(app) (switching=false のため確定せず)")
        }
    }

    /// 自分が Mission Control を開いた: フラグを立て、他端末へ「開く」合図を送る
    func noteLocalOpen() {
        guard enabled, !switching else { return }
        setFlag(true)
        broadcast("swopen")
        onNote?("Mission Control を検知: 合図を送りました")
    }

    /// Ctrl+↑ や MCキー: 開いていなければ「開いた」合図、開いているときは確定(トグルで閉じた)
    func noteOpenKey() {
        guard enabled else { return }
        NetLog.shared.log("MC検知: noteOpenKey (switching=\(switching))")
        if switching { decide(reason: "キーのトグル") } else { noteLocalOpen() }
    }

    /// トラックパッドの4本指縦スワイプ(Engine が検知): 上で一覧を開く。
    /// 切り替え中の下スワイプは「閉じた=確定」として扱う。
    /// 下スワイプでは開かない: その操作は App Exposé で、連動対象外にしたため
    /// (Exposé は手元のアプリの一覧で、他端末の Mission Control と揃わず不安定だった)
    func noteGesture(up: Bool) {
        guard enabled else { return }
        if !up && !switching { return }
        NetLog.shared.log("MC検知: 縦スワイプ (up=\(up))")
        if switching {
            if !up { decide(reason: "下スワイプ") }
        } else {
            noteLocalOpen()
        }
    }

    /// 自分が Esc で一覧を閉じた: 確定と同じ扱いで、他端末の一覧も閉じさせる
    func noteLocalEsc() {
        guard enabled, switching else { return }
        decide(reason: "Esc")
    }

    /// 合図を受けて自分の Mission Control を開く
    func openLocal() {
        // 既に開いているときに Ctrl+↑ をもう一度送ると、トグルで閉じてしまう
        guard enabled, !switching else { return }
        setFlag(true)
        onNote?("合図を受けて Mission Control を開きます")
        postKey(126, flags: .maskControl)
    }

    /// 他端末から「確定」を受けた: 一覧を開いているときだけ Esc で閉じる
    func receiveDone() {
        guard enabled, switching else { return }
        NetLog.shared.log("swdone受信: Escで閉じる")
        setFlag(false)
        postKey(53, flags: [])
    }

    private func decide(reason: String) {
        guard switching else { return }
        NetLog.shared.log("確定: 理由=\(reason)")
        setFlag(false)
        broadcast("swdone")
        onNote?("確定を送りました")
    }

    private func broadcast(_ kind: String) {
        NetLog.shared.log("送信 \(kind)")
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

    /// 本物のキーイベントが持っている flags を再現する。
    /// 実測(キー適用ログ): 本物の Ctrl+↑ は kd の flags が 0xA40101 で、素の maskControl(0x40000)
    /// とは大きく違う。矢印キーには Fn(0x800000)と NumericPad(0x200000)が付き、全イベントに
    /// NonCoalesced(0x100)、修飾キーには左右デバイスビット(Ctrl=0x1, Shift=0x2, Cmd=0x8, Opt=0x20)が付く。
    /// Dock のショートカット判定は、この完全な形でないと受け付けないらしい
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
        // 修飾キーは flagsChanged として独立に送り、さらに本体キーとは間隔を空けて送る。
        // 一息に全部送ると Dock のショートカット判定が修飾キーの変化を取りこぼす疑いがあるため、
        // 人間の押下(修飾キーを押してから本体キー)に近づける。
        // flags は本物そっくりにする(realisticFlags)。素の mask だけでは Dock が判定しない
        var mods: [(CGKeyCode, CGEventFlags)] = []
        if flags.contains(.maskControl) { mods.append((59, .maskControl)) }
        if flags.contains(.maskCommand) { mods.append((55, .maskCommand)) }
        if flags.contains(.maskAlternate) { mods.append((58, .maskAlternate)) }
        if flags.contains(.maskShift) { mods.append((56, .maskShift)) }
        let keyFlags = realisticFlags(for: keyCode, mods: flags)
        NetLog.shared.log("キー合成: code=\(keyCode) flags=\(flags.rawValue) 実flags=\(keyFlags.rawValue)")
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

// MARK: - 検索の連動 (⌘+Space)
/// どこかの Mac で ⌘+Space を押すと、他の端末でも検索が開き、打った文字が全端末に届く。
/// Enter で各端末の最上位ヒットを開いて閉じ、Esc / クリック / 他アプリへの切替で全端末の検索を閉じる。
/// 起点は Mac のみ(Windows は受ける側)。IME の変換は送られないので、英数字での検索向き。
final class SearchSync {
    static let shared = SearchSync()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "searchSync") == nil ? true : UserDefaults.standard.bool(forKey: "searchSync") }
        set { UserDefaults.standard.set(newValue, forKey: "searchSync") }
    }

    private(set) var origin = false     // 自分が起点(打鍵を送る側)
    private(set) var receiving = false  // 合図を受けて検索を開いている側
    private var timer: Timer?
    private var loggedApply = false
    private var openedAt = Date.distantPast
    private var originTextLen = 0
    var onNote: ((String) -> Void)?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated() {
        // 起点で他のアプリに切り替わった = 検索が終わった
        if origin { noteLocalEnd() }
        // 受け側で他のアプリに切り替わった = 自分の検索は閉じた
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
        // 受け側はキー合成で閉じない。終了合図が来なかった場合に遅れて Esc を送ると
        // 関係ない操作に割り込んでしまうため、状態だけ静かに畳む
        receiving = false
        disarm()
    }

    // MARK: 起点側

    /// 手元で ⌘+Space を押した
    func noteLocalOpen() {
        guard enabled, !receiving, !origin else { return }
        origin = true
        originTextLen = 0
        armTimer()
        sendAll("srch")
    }

    /// 起点の Esc: 検索文字列が残っているときの Esc は「消去」であって終了ではない。
    /// Spotlight が開いているかは外部から判定できないため、フォーカス先などは見ず、
    /// 自分が転送した打鍵の数で判断する(文字があるうちは連動を続け、空のときだけ全台を閉じる)
    func forwardKey(keycode: Int64) {
        guard origin else { return }
        if originTextLen > 0 {
            originTextLen = 0
            return
        }
        noteLocalEnd()
    }

    /// 起点の打鍵を、カーソル共有と同じ kd/ku/fl の形で全端末へ送る
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
            // Esc の意味(消去か終了か)を判断するため、検索文字列の長さを数えておく
            if kc == 51 { originTextLen = max(0, originTextLen - 1) }
            else if kc != 36 && kc != 76 && kc != 48 && !(123...126).contains(kc) { originTextLen += 1 }
        }
        sendAll(kind, "\(kc) \(event.flags.rawValue)")
    }

    /// 起点の検索終了: 他端末の検索も閉じる
    func noteLocalEnd() {
        guard origin else { return }
        origin = false
        disarm()
        sendAll("sdone")
    }

    // MARK: 受信側

    func receiveOpen() {
        guard enabled, !origin, !receiving else { return }
        receiving = true
        loggedApply = false
        openedAt = Date()
        armTimer()
        NetLog.shared.log("検索連動: 受け側開始")
        postKeyCode(49, flags: .maskCommand)
    }

    func receiveQuery(_ b64: String) {
        guard receiving else { return }
        // 自分の検索が最前面でなければ、閉じられたとみなして何もしない(他のアプリへ打ってしまう事故防止)
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

    /// 受け側: 起点から届いた打鍵(kd/ku/fl)をそのまま再現する。
    /// Spotlight が開いているかは外部から判定できない(macOS 27 では Spotlight のウィンドウが
    /// CGWindowList にも最前面アプリにも現れない)ため、判定はせず、連動中(receiving)であることを
    /// もって再現する。連動は sdone / アプリ切替 / 30秒タイムアウトで必ず終わる
    func applyRemoteKey(kind: String, args: [String]) {
        guard receiving, args.count == 2, let code = UInt16(args[0]), let flagsRaw = UInt64(args[1]) else { return }
        if !loggedApply {
            loggedApply = true
            NetLog.shared.log("検索連動: 打鍵の再現を開始しました")
        }
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: kind != "ku") {
            e.flags = CGEventFlags(rawValue: flagsRaw)
            if kind == "fl" { e.type = .flagsChanged }
            CursorShare.markSynthetic(e)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: キーの合成

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

    /// 自分の Spotlight を閉じる。Spotlight の Esc は「1回目=検索文字の消去、2回目=閉じる」
    /// という仕様なので、人間が2回押すのと同じく、間隔を空けて無条件に2回送る。
    /// 開いているかの外部判定(AX のフォーカス先など)は受け側では当てにならないため使わない
    private func closeLocal() {
        SwitchSync.shared.postKey(53, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SwitchSync.shared.postKey(53, flags: [])
        }
    }

    /// 検索欄を全選択してから中身を入れ替える
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

// MARK: - ログ (全端末で足跡を残す)
/// 送受信と主要な動作を、メモリと Documents/cursor-log.txt の両方に残す
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
        log("=== 起動 \(buildTag) ID=\(LinkNet.machineID) ===")
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
        w.title = "ログ"
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
        // 「有効」に束ねたため、旧来の個別設定が食い違っていたら「有効」に合わせる
        let masterEnabled = Engine.shared.enabled
        if Engine.shared.linkMode != masterEnabled { Engine.shared.linkMode = masterEnabled; UserDefaults.standard.set(masterEnabled, forKey: "linkMode") }
        if CursorShare.shared.enabled != masterEnabled { CursorShare.shared.enabled = masterEnabled; UserDefaults.standard.set(masterEnabled, forKey: "cursorShare") }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = fingerIcon()
        let menu = NSMenu()
        let buildItem = NSMenuItem(title: buildTag, action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        cursorAtItem = NSMenuItem(title: "カーソル: 自分", action: nil, keyEquivalent: "")
        cursorAtItem.isEnabled = false
        enabledItem = NSMenuItem(title: "有効", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        remoteItem = NSMenuItem(title: "リモート操作モード（リモート越しでも有効）", action: #selector(toggleRemote), keyEquivalent: "")
        remoteItem.target = self
        linkItem = NSMenuItem(title: "相方モード（ネットワークで合図を送受信）", action: #selector(toggleLink), keyEquivalent: "")
        linkItem.target = self
        cursorItem = NSMenuItem(title: "カーソル共有（端で相手に渡す）", action: #selector(toggleCursor), keyEquivalent: "")
        cursorItem.target = self
        snapItem = NSMenuItem(title: "ダイアログの既定ボタンへカーソルを移動", action: #selector(toggleSnap), keyEquivalent: "")
        switchItem = NSMenuItem(title: "Mission Control／タスクビュー連動", action: #selector(toggleSwitch), keyEquivalent: "")
        switchItem.target = self
        searchItem = NSMenuItem(title: "検索の連動", action: #selector(toggleSearch), keyEquivalent: "")
        searchItem.target = self
        soloItem = NSMenuItem(title: "単独モード", action: #selector(toggleSolo), keyEquivalent: "")
        soloItem.target = self
        logItem = NSMenuItem(title: "ログを表示", action: #selector(showLog), keyEquivalent: "")
        logItem.target = self
        snapItem.target = self
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
        let permItem = NSMenuItem(title: "デバイスの制御とデータへのアクセスの許可を開く…", action: #selector(openPermSettings), keyEquivalent: "")
        permItem.target = self
        let screenItem = NSMenuItem(title: "画面収録とシステムオーディオ録音の許可を開く…", action: #selector(openScreenSettings), keyEquivalent: "")
        screenItem.target = self
        let inputItem = NSMenuItem(title: "入力監視の許可を開く…", action: #selector(openInputSettings), keyEquivalent: "")
        inputItem.target = self
        menu.addItem(buildItem); menu.addItem(cursorAtItem); menu.addItem(.separator()); menu.addItem(enabledItem); menu.addItem(remoteItem); menu.addItem(snapItem); menu.addItem(switchItem); menu.addItem(searchItem); menu.addItem(soloItem); menu.addItem(layoutItem); menu.addItem(moveParent); menu.addItem(lastItem); menu.addItem(mtItem); menu.addItem(statsItem); menu.addItem(diagItem); menu.addItem(logItem); menu.addItem(.separator())
        menu.addItem(permItem); menu.addItem(screenItem); menu.addItem(inputItem); menu.addItem(.separator())
        cursorShowItem = NSMenuItem(title: "カーソルを常時表示", action: #selector(toggleCursorShow), keyEquivalent: "")
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
        let relaunchItem = NSMenuItem(title: "再起動", action: #selector(relaunchSelf), keyEquivalent: "")
        relaunchItem.target = self
        menu.addItem(relaunchItem)
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

        // キーを送るにはデバイスの制御とデータへのアクセスの許可が要る
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            alert("デバイスの制御とデータへのアクセスの許可が必要です",
                  "スワイプで Finder にキーを送るため、システム設定 → プライバシーとセキュリティ → デバイスの制御とデータへのアクセス で OneManCursor を許可してください。許可したら OneManCursor を再起動してください。")
        }

        NetLog.shared.start()
        LinkNet.startReceiver()
        LinkNet.startHello()
        LinkNet.startTCP()
        DialogSnap.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        DialogSnap.shared.start()
        SwitchSync.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        SwitchSync.shared.start()
        SearchSync.shared.onNote = { [weak self] label in
            self?.flashIcon()
            self?.lastItem.title = "最後の検出： \(label)"
        }
        SearchSync.shared.start()

        cursorOverlay.start()
        refreshCursorMenu()

        let devices = Multitouch.start()
        mtItem.title = devices > 0 ? "トラックパッド： 接続OK（\(devices)台）" : "トラックパッド： 接続失敗"
        startTrackpadWatchdog(initialDevices: devices)
        if devices == 0 {
            alert("トラックパッドを読み込めませんでした",
                  "MultitouchSupport を開くか、トラックパッドの検出に失敗しました。この Mac では試作方式が使えない可能性があります。")
        }
    }

    // MARK: 指データの監視(固まったら自動で登録し直す)

    private var watchdogTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastDeviceCount = 0

    /// トラックパッドの指データは、長時間動かしていると登録が固まって
    /// 「フレームは来るのに指が1本しか取れない」状態になることがある(実測あり)。
    /// スリープ復帰のときと、一定時間ずっと1本しか取れない状態を検知したときに、
    /// アプリを再起動しなくても済むよう、登録をやり直す
    private func startTrackpadWatchdog(initialDevices: Int) {
        lastDeviceCount = initialDevices
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reregisterTrackpads(reason: "スリープ復帰")
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
            reregisterTrackpads(reason: "自動検知")
        }
    }

    private func reregisterTrackpads(reason: String) {
        let n = Multitouch.start()
        NetLog.shared.log("指データを再登録: \(reason) (デバイス\(n)台)")
        if n != lastDeviceCount {
            lastDeviceCount = n
            mtItem.title = n > 0 ? "トラックパッド： 接続OK（\(n)台）" : "トラックパッド： 接続失敗"
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
            cursorAtItem.title = "カーソル: \(LayoutStore.name(of: hid))"
        } else {
            cursorAtItem.title = "カーソル: 自分"
        }
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
        // 「有効」はスワイプ・相方(合図の送受信)・カーソル共有をまとめて切り替える
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
            alert("ログイン項目を変更できませんでした", error.localizedDescription)
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

    /// 最後の検出・トラックパッド・受信数の3行は診断用。普段は隠しておけるようにする
    private func applyDiagVisibility() {
        let v = UserDefaults.standard.bool(forKey: "showDiag")
        lastItem.isHidden = !v
        mtItem.isHidden = !v
        statsItem.isHidden = !v
    }

    /// 不調時の立て直し用: 別インスタンスとして自分を起動し直してから終了する
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
