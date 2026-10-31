import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

// ワンマンカーソル(OneManCursor)のカーソル表示部。AlwaysCursor 由来のコードを取り込んだもの。
// オーバーレイの追従・形・波紋・設定画面を担当する。
// カーソル共有で操作を渡している間は、CursorShare.sessionActiveAway を見て描画を止める。

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

let S: CGFloat = 260         // ウィンドウ一辺。中心がカーソルの先端(ホットスポット)
let K0: CGFloat = 0.7425     // サイズ 1.0 のときの倍率

// MARK: - 保存

enum Prefs {
    static func double(_ key: String, default def: Double) -> Double {
        (UserDefaults.standard.object(forKey: key) as? Double) ?? def
    }
    static func colorData(_ c: NSColor) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true)) ?? Data()
    }
    static func rgba(_ c: NSColor) -> [Double] {
        let s = c.usingColorSpace(.sRGB) ?? c
        return [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent)]
    }
    static func color(rgba a: Any?) -> NSColor? {
        guard let v = a as? [Double], v.count == 4 else { return nil }
        return NSColor(srgbRed: v[0], green: v[1], blue: v[2], alpha: v[3])
    }
    static func color(from d: Data?) -> NSColor? {
        guard let d else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: d)
    }
}

/// 形ごと(矢印 / 丸)の見た目の設定。形ごとに別々に保存される
final class Profile {
    var scale: CGFloat = 1
    var outlineOn = true
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var blur: CGFloat = 0
    var fillOn = false
    var fillColor: NSColor = NSColor.systemRed.withAlphaComponent(0.4)
    var opacity: CGFloat = 1

    func save(_ key: String) {
        UserDefaults.standard.set([
            "scale": Double(scale), "outlineOn": outlineOn, "color": Prefs.colorData(color),
            "lineWidth": Double(lineWidth), "blur": Double(blur), "fillOn": fillOn,
            "fillColor": Prefs.colorData(fillColor), "opacity": Double(opacity),
        ] as [String: Any], forKey: key)
    }

    /// JSON 書き出し用(色は RGBA の数値)
    func exported() -> [String: Any] {
        ["scale": Double(scale), "outlineOn": outlineOn, "color": Prefs.rgba(color), "lineWidth": Double(lineWidth),
         "blur": Double(blur), "fillOn": fillOn, "fillColor": Prefs.rgba(fillColor), "opacity": Double(opacity)]
    }
    /// JSON 読み込み。無い項目は今の値のまま
    func apply(_ d: [String: Any]) {
        if let v = d["scale"] as? Double { scale = CGFloat(min(max(v, 0.3), 4)) }
        if let v = d["outlineOn"] as? Bool { outlineOn = v }
        if let c = Prefs.color(rgba: d["color"]) { color = c }
        if let v = d["lineWidth"] as? Double { lineWidth = CGFloat(min(max(v, 0.5), 20)) }
        if let v = d["blur"] as? Double { blur = CGFloat(min(max(v, 0), 10)) }
        if let v = d["fillOn"] as? Bool { fillOn = v }
        if let c = Prefs.color(rgba: d["fillColor"]) { fillColor = c }
        if let v = d["opacity"] as? Double { opacity = CGFloat(min(max(v, 0.1), 1)) }
    }

    /// 保存済みがあればそれを、なければ旧バージョンの共通設定(scale / color …)を引き継ぐ
    static func load(_ key: String) -> Profile {
        let p = Profile()
        let ud = UserDefaults.standard
        if let d = ud.dictionary(forKey: key) {
            p.scale = CGFloat(d["scale"] as? Double ?? 1)
            p.outlineOn = d["outlineOn"] as? Bool ?? true
            p.color = Prefs.color(from: d["color"] as? Data) ?? .systemRed
            p.lineWidth = CGFloat(d["lineWidth"] as? Double ?? 3)
            p.blur = CGFloat(d["blur"] as? Double ?? 0)
            p.fillOn = d["fillOn"] as? Bool ?? false
            p.fillColor = Prefs.color(from: d["fillColor"] as? Data) ?? p.fillColor
            p.opacity = CGFloat(d["opacity"] as? Double ?? 1)
        } else {
            p.scale = CGFloat(Prefs.double("scale", default: 1))
            p.color = Prefs.color(from: ud.data(forKey: "color")) ?? .systemRed
            p.lineWidth = CGFloat(Prefs.double("lineWidth", default: 3))
            p.blur = CGFloat(Prefs.double("blur", default: 0))
            p.fillOn = ud.bool(forKey: "fillOn")
            p.fillColor = Prefs.color(from: ud.data(forKey: "fillColor")) ?? p.fillColor
        }
        return p
    }
}

// MARK: - 表示

/// 標準カーソルの形をした矢印、または丸。本物のカーソルはウィンドウより常に前面
final class ArrowView: NSView {
    var profile = Profile() { didSet { applyBlur(); needsDisplay = true } }
    var circle = false { didSet { needsDisplay = true } }
    // 本物そっくりモード: 本物のカーソルの画像をそのまま拡大して描く
    var mirror = false { didSet { needsDisplay = true } }
    var mirrorImage: NSImage? { didSet { needsDisplay = true } }
    var mirrorHotSpot = NSPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() { applyBlur(); needsDisplay = true }
    func applyBlur() {
        if profile.blur > 0, let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: profile.blur]) {
            layer?.filters = [f]
        } else {
            layer?.filters = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let x = bounds.midX, y = bounds.midY
        if mirror {
            // 本物のカーソルの画像を、ホットスポットが中心に来るよう拡大して描く
            if let img = mirrorImage {
                let s = img.size
                let w = s.width * profile.scale, h = s.height * profile.scale
                let rect = NSRect(x: x - mirrorHotSpot.x * profile.scale,
                                  y: y - (s.height - mirrorHotSpot.y) * profile.scale,
                                  width: w, height: h)
                img.draw(in: rect, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
            }
            return
        }
        let K = K0 * profile.scale
        func pt(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint { NSPoint(x: x + dx * K, y: y - dy * K) }
        let a: NSBezierPath
        if circle {
            let r = 28 * K          // 先端(ホットスポット)を中心にした丸
            a = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        } else {
            a = NSBezierPath()
            a.move(to: pt(0, 0))
            a.line(to: pt(0, 17))
            a.line(to: pt(4, 13))
            a.line(to: pt(7.5, 20))
            a.line(to: pt(10, 19))
            a.line(to: pt(6.5, 12))
            a.line(to: pt(12, 12))
            a.close()
        }
        a.lineJoinStyle = .round
        if profile.fillOn { profile.fillColor.setFill(); a.fill() }
        if profile.outlineOn { profile.color.setStroke(); a.lineWidth = profile.lineWidth; a.stroke() }
    }
}

// MARK: - 設定画面の部品

/// 角丸を小さくした色見本。クリックで標準のカラーパネルを開く
final class SwatchView: NSView {
    var color: NSColor = .systemRed { didSet { layer?.backgroundColor = color.cgColor } }
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// スライダーと数値入力が連動する1行。key があれば UserDefaults に保存する
final class ParamRow: NSObject {
    let key: String?, minV: Double, maxV: Double, step: Double, fmt: String
    let slider: NSSlider, field: NSTextField, stack: NSStackView
    var onChange: ((Double) -> Void)?
    var value: Double

    init(label: String, unit: String, key: String? = nil, min: Double, max: Double, step: Double, fmt: String, value: Double) {
        self.key = key; minV = min; maxV = max; self.step = step; self.fmt = fmt; self.value = value
        slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        field = NSTextField(string: String(format: fmt, value))
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let l = NSTextField(labelWithString: label)
        l.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let u = NSTextField(labelWithString: unit)
        u.widthAnchor.constraint(equalToConstant: 22).isActive = true
        stack = NSStackView(views: [l, slider, field, u])
        stack.spacing = 6
        super.init()
        slider.target = self; slider.action = #selector(sliderMoved)
        field.target = self; field.action = #selector(fieldEntered)
    }
    /// 画面の表示だけ更新(onChange は呼ばない)
    func show(_ v: Double) {
        value = v
        slider.doubleValue = v
        field.stringValue = String(format: fmt, v)
    }
    func set(_ v: Double) {
        show(v)
        if let key { UserDefaults.standard.set(v, forKey: key) }
        onChange?(v)
    }
    @objc func sliderMoved() { set((slider.doubleValue / step).rounded() * step) }
    @objc func fieldEntered() {
        if let v = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) { set(Swift.min(Swift.max(v, minV), maxV)) }
        else { field.stringValue = String(format: fmt, value) }
    }
}

// MARK: - アプリ本体

final class CursorOverlay: NSObject {
    var showArrow = true
    var overlay: NSWindow!
    var displayLink: AnyObject?     // macOS 14 以降は CADisplayLink、それ未満は Timer
    var cmdTimer: Timer?            // Command キーの確認(低頻度)
    var lastOrigin = NSPoint(x: -99999, y: -99999)
    var monitors: [Any] = []
    var settingsWindow: NSWindow?

    // 先読み用: 直近の速度(pt/秒)と最後に動いた時刻
    var velocity = CGPoint.zero
    var lastPos = NSEvent.mouseLocation
    var lastTime = CACurrentMediaTime()
    var lead = CGFloat(Prefs.double("leadMs", default: 0)) / 1000      // 何秒先に置くか(0 で先読みなし)
    var smooth = CGFloat(Prefs.double("smooth", default: 0.4))         // 速度の平滑化(大きいほどなめらか)
    var stopDelay = Prefs.double("stopMs", default: 30) / 1000         // 動きが止まったとみなす時間

    // 形ごとの設定。0 = 矢印、1 = 丸、2 = 本物そっくり
    let profiles = [Profile.load("profile.arrow"), Profile.load("profile.circle"), Profile.load("profile.mirror")]
    var shape = UserDefaults.standard.object(forKey: "shape") as? Int ?? (UserDefaults.standard.bool(forKey: "circle") ? 1 : 0)
    var lastCursor: NSCursor?
    var cur: Profile { profiles[shape] }
    var arrowView: ArrowView? { overlay.contentView as? ArrowView }

    // 設定画面の部品
    var shapeControl: NSSegmentedControl!
    var sizeRow: ParamRow!, widthRow: ParamRow!, blurRow: ParamRow!, opacityRow: ParamRow!
    var followRows: [ParamRow] = []
    var outlineCheck: NSButton!, fillCheck: NSButton!
    var outlineSwatch: SwatchView!, fillSwatch: SwatchView!
    var editingTarget = 0           // カラーパネルの対象: 0 = 輪郭、1 = 本体、2 = 波紋

    // 波紋(Command 単独タップ)
    var rippleOn = UserDefaults.standard.object(forKey: "rippleOn") as? Bool ?? true
    var rippleRadius = CGFloat(Prefs.double("rippleRadius", default: 110))
    var rippleColor = Prefs.color(from: UserDefaults.standard.data(forKey: "rippleColor")) ?? .systemRed
    var rippleWindow: NSWindow?
    var rippleHide: DispatchWorkItem?
    var cmdDownAt: CFTimeInterval?
    var cmdClean = false
    var rippleCheck: NSButton!, rippleSwatch: SwatchView!, rippleRow: ParamRow!

    // Mission Control / アプリケーション Exposé の間は隠す(任意設定)
    var hideDuringMC = UserDefaults.standard.bool(forKey: "hideDuringMC")
    var mcActive = false
    var mcPollCount = 0
    var mcCheck: NSButton!

    func start() {
        _ = CGSSetConnectionProperty(CGSMainConnectionID(), CGSMainConnectionID(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        // 本物そっくりモードの初期サイズは 2 倍(本物と同じ大きさでは小さいので)
        if UserDefaults.standard.dictionary(forKey: "profile.mirror") == nil { profiles[2].scale = 2 }

        overlay = NSWindow(contentRect: NSRect(x: 0, y: 0, width: S, height: S), styleMask: .borderless, backing: .buffered, defer: false)
        overlay.backgroundColor = .clear; overlay.isOpaque = false; overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .screenSaver
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.contentView = ArrowView(frame: NSRect(x: 0, y: 0, width: S, height: S))
        applyShape()

        // マウスの動きが来た瞬間に追従(イベント駆動)
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.wake(); self?.follow() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.wake(); self?.follow(); return e }) { monitors.append(m) }
        // 画面の更新にも同期(120Hz 画面なら 120 回/秒)
        if #available(macOS 14.0, *) {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let link = screen.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let t = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            displayLink = t
        }
        let ct = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(cmdTick), userInfo: nil, repeats: true)
        ct.tolerance = 0.02
        RunLoop.main.add(ct, forMode: .common)
        cmdTimer = ct
    }

    // MARK: 追従

    @objc func cmdTick() {
        checkCommand()
        updateMirrorCursor()
        // Mission Control の検出は少し間引いて確認する(約5回/秒)
        if hideDuringMC || mcActive {
            mcPollCount += 1
            if mcPollCount >= 6 { mcPollCount = 0; checkMissionControl() }
        }
    }

    /// Mission Control / アプリケーション Exposé が表示中かどうか
    /// 公式の判定方法は無いので、Dock が画面全体サイズのウィンドウを出しているかで推定する
    func missionControlActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "Dock",
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let sw = (b["Width"] as? NSNumber)?.doubleValue,
                  let sh = (b["Height"] as? NSNumber)?.doubleValue else { continue }
            for s in NSScreen.screens where sw >= Double(s.frame.width) * 0.9 && sh >= Double(s.frame.height) * 0.9 { return true }
        }
        return false
    }

    func checkMissionControl() {
        let active = missionControlActive()
        guard active != mcActive else { return }
        mcActive = active
        if active {
            overlay.orderOut(nil)
            rippleWindow?.orderOut(nil)
        } else {
            // 戻ってきたら現在位置から追従を再開する
            lastOrigin = NSPoint(x: -99999, y: -99999)
            lastPos = NSEvent.mouseLocation; lastTime = CACurrentMediaTime(); velocity = .zero
            follow()
        }
    }

    @objc func mcToggled(_ b: NSButton) {
        hideDuringMC = b.state == .on
        UserDefaults.standard.set(hideDuringMC, forKey: "hideDuringMC")
        if hideDuringMC { checkMissionControl() }
        else if mcActive { mcActive = false; lastOrigin = NSPoint(x: -99999, y: -99999); follow() }
    }

    /// 画面更新への同期は、動いている間だけ働かせる(止まっている間は休ませて電力を節約)
    func wake() {
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.isPaused = false }
    }
    func sleepLink() {
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.isPaused = true }
    }

    @objc func tick() {
        follow()
        // 止まって十分たったら休ませる(先読みの収束と停止判定のぶん余裕を持つ)
        if CACurrentMediaTime() - lastTime > stopDelay + 0.15 { sleepLink() }
    }

    /// Command 単独のタップ(押して短時間で離す。他のキーやクリックを挟まない)を検知して波紋を出す
    func checkCommand() {
        guard rippleOn, !CursorShare.shared.sessionActiveAway else { cmdDownAt = nil; return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let cmd = flags.contains(.maskCommand)
        let others = flags.contains(.maskShift) || flags.contains(.maskAlternate) || flags.contains(.maskControl)
        let now = CACurrentMediaTime()
        if cmd, cmdDownAt == nil {
            cmdDownAt = now
            cmdClean = !others
        } else if cmd {
            if others { cmdClean = false }
        } else if let t = cmdDownAt {
            cmdDownAt = nil
            let held = now - t
            let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            let sinceClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            if cmdClean, held < 0.5, sinceKey > held, sinceClick > held { showRipple() }
        }
    }

    func showRipple() {
        let R = rippleRadius
        let side = (R + 20) * 2
        if rippleWindow == nil || abs(rippleWindow!.frame.width - side) > 1 {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: .borderless, backing: .buffered, defer: false)
            w.backgroundColor = .clear; w.isOpaque = false; w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            v.wantsLayer = true
            w.contentView = v
            rippleWindow = w
        }
        guard let w = rippleWindow, let host = w.contentView?.layer else { return }
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        let p = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: p.x - side / 2, y: p.y - side / 2))
        w.orderFrontRegardless()
        // 外側から中心へ縮む3重の輪(Windows の「Ctrl で位置を知らせる」風)
        for i in 0..<3 {
            let ring = CAShapeLayer()
            ring.frame = NSRect(x: 0, y: 0, width: side, height: side)
            ring.path = CGPath(ellipseIn: CGRect(x: side / 2 - R, y: side / 2 - R, width: R * 2, height: R * 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = rippleColor.cgColor
            ring.lineWidth = 4
            ring.opacity = 0
            host.addSublayer(ring)
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0; scale.toValue = 0.12
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.1, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [scale, fade]
            g.duration = 0.7
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.14
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .backwards
            ring.add(g, forKey: "ripple")
        }
        rippleHide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rippleWindow?.orderOut(nil) }
        rippleHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + 0.28 + 0.1, execute: item)
    }

    func follow() {
        // カーソル共有で操作を相手に渡している間は描かない(描くと二重カーソルになる)
        if CursorShare.shared.sessionActiveAway {
            if overlay.isVisible { overlay.orderOut(nil) }
            return
        }
        let now = CACurrentMediaTime()
        let p = NSEvent.mouseLocation
        let dt = now - lastTime
        if p != lastPos, dt > 0.0005 {
            // 速度を少しなめらかにして推定
            let v = CGPoint(x: (p.x - lastPos.x) / dt, y: (p.y - lastPos.y) / dt)
            velocity = CGPoint(x: velocity.x * smooth + v.x * (1 - smooth), y: velocity.y * smooth + v.y * (1 - smooth))
            lastPos = p; lastTime = now
        } else if now - lastTime > stopDelay {
            velocity = .zero            // 止まったら先読みをやめる(行き過ぎ防止)
        }
        let target = NSPoint(x: p.x + velocity.x * lead, y: p.y + velocity.y * lead)
        if showArrow && !mcActive {
            let o = NSPoint(x: (target.x - S/2).rounded(), y: (target.y - S/2).rounded())
            if o != lastOrigin { overlay.setFrameOrigin(o); lastOrigin = o }
            if !overlay.isVisible { overlay.orderFrontRegardless() }
        }
        if let rw = rippleWindow, rw.isVisible {
            let o = NSPoint(x: (p.x - rw.frame.width / 2).rounded(), y: (p.y - rw.frame.height / 2).rounded())
            if o != rw.frame.origin { rw.setFrameOrigin(o) }
        }
    }

    func refreshMenu() {
        if !showArrow { overlay.orderOut(nil) }
    }
    @objc func toggleArrow() { showArrow.toggle(); lastOrigin = NSPoint(x: -99999, y: -99999); refreshMenu(); follow() }

    // MARK: 形・見た目の反映

    /// 選んでいる形の設定を表示に反映する
    func applyShape() {
        guard let v = arrowView else { return }
        v.circle = shape == 1
        v.mirror = shape == 2
        v.profile = cur
        overlay.alphaValue = cur.opacity
        if shape == 2 { lastCursor = nil; updateMirrorCursor() }
    }
    /// 見た目が変わったときの共通処理(反映して保存)
    func profileChanged() {
        arrowView?.refresh()
        overlay.alphaValue = cur.opacity
        cur.save(["profile.arrow", "profile.circle", "profile.mirror"][shape])
    }

    @objc func shapeChanged(_ c: NSSegmentedControl) {
        shape = c.selectedSegment
        UserDefaults.standard.set(shape, forKey: "shape")
        UserDefaults.standard.set(shape == 1, forKey: "circle")
        applyShape()
        refreshControls()
    }

    /// 本物そっくりモード用: いま表示されている本物のカーソルを取り込んで描き替える
    func updateMirrorCursor() {
        guard shape == 2, let v = arrowView else { return }
        let c = NSCursor.currentSystem ?? NSCursor.arrow
        if c !== lastCursor {
            lastCursor = c
            v.mirrorImage = c.image
            v.mirrorHotSpot = c.hotSpot
        }
    }

    /// 選んでいる形の設定値を設定画面に表示する
    func refreshControls() {
        guard settingsWindow != nil else { return }
        shapeControl.selectedSegment = shape
        sizeRow.show(Double(cur.scale))
        widthRow.show(Double(cur.lineWidth))
        blurRow.show(Double(cur.blur))
        opacityRow.show(Double(cur.opacity))
        outlineCheck.state = cur.outlineOn ? .on : .off
        fillCheck.state = cur.fillOn ? .on : .off
        outlineSwatch.color = cur.color; outlineSwatch.alphaValue = cur.outlineOn ? 1 : 0.35
        fillSwatch.color = cur.fillColor; fillSwatch.alphaValue = cur.fillOn ? 1 : 0.35
        // 本物そっくりは本物のカーソル画像をそのまま拡大するので、色・輪郭の太さ・ぼかしは
        // 効かない。効かない設定は操作できないようにする(サイズと不透明度は効く)
        let mirror = shape == 2
        outlineCheck.isEnabled = !mirror
        fillCheck.isEnabled = !mirror
        widthRow.slider.isEnabled = !mirror; widthRow.field.isEnabled = !mirror
        blurRow.slider.isEnabled = !mirror; blurRow.field.isEnabled = !mirror
        if mirror { outlineSwatch.alphaValue = 0.35; fillSwatch.alphaValue = 0.35 }
    }

    // MARK: 色

    func openColorPanel(target: Int) {
        if shape == 2, target != 2 { return }   // 本物そっくりでは色が効かない
        editingTarget = target
        let p = NSColorPanel.shared
        p.showsAlpha = true
        p.color = target == 2 ? rippleColor : (target == 1 ? cur.fillColor : cur.color)
        p.setTarget(self); p.setAction(#selector(panelColorChanged(_:)))
        p.makeKeyAndOrderFront(nil)
    }
    @objc func panelColorChanged(_ p: NSColorPanel) {
        switch editingTarget {
        case 2:
            rippleColor = p.color; rippleSwatch?.color = p.color
            UserDefaults.standard.set(Prefs.colorData(p.color), forKey: "rippleColor")
        case 1: cur.fillColor = p.color; fillSwatch.color = p.color; profileChanged()
        default: cur.color = p.color; outlineSwatch.color = p.color; profileChanged()
        }
    }
    @objc func outlineToggled(_ b: NSButton) {
        cur.outlineOn = b.state == .on
        outlineSwatch.alphaValue = cur.outlineOn ? 1 : 0.35
        profileChanged()
    }
    @objc func fillToggled(_ b: NSButton) {
        cur.fillOn = b.state == .on
        fillSwatch.alphaValue = cur.fillOn ? 1 : 0.35
        profileChanged()
    }
    @objc func rippleToggled(_ b: NSButton) {
        rippleOn = b.state == .on
        UserDefaults.standard.set(rippleOn, forKey: "rippleOn")
        rippleSwatch?.alphaValue = rippleOn ? 1 : 0.35
    }
    // MARK: 設定の書き出し / 読み込み

    @objc func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AlwaysCursor-settings.json"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let obj: [String: Any] = [
            "app": "AlwaysCursor", "version": 1,
            "shape": shape == 2 ? "mirror" : (shape == 1 ? "circle" : "arrow"),
            "profiles": ["arrow": profiles[0].exported(), "circle": profiles[1].exported(), "mirror": profiles[2].exported()],
            "follow": ["leadMs": Double(lead) * 1000, "smooth": Double(smooth), "stopMs": stopDelay * 1000],
            "ripple": ["on": rippleOn, "radius": Double(rippleRadius), "color": Prefs.rgba(rippleColor)],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        } catch { alert("書き出せませんでした", error.localizedDescription) }
    }

    @objc func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], obj["app"] as? String == "AlwaysCursor" else {
                alert("読み込めませんでした", "AlwaysCursor の設定ファイルではないようです。"); return
            }
            if let p = obj["profiles"] as? [String: Any] {
                if let a = p["arrow"] as? [String: Any] { profiles[0].apply(a) }
                if let c = p["circle"] as? [String: Any] { profiles[1].apply(c) }
                if let m = p["mirror"] as? [String: Any] { profiles[2].apply(m) }
            }
            profiles[0].save("profile.arrow"); profiles[1].save("profile.circle"); profiles[2].save("profile.mirror")
            if let sh = obj["shape"] as? String {
                shape = sh == "mirror" ? 2 : (sh == "circle" ? 1 : 0)
                UserDefaults.standard.set(shape, forKey: "shape")
                UserDefaults.standard.set(shape == 1, forKey: "circle")
            }
            if let f = obj["follow"] as? [String: Any], followRows.count == 3 {
                if let v = f["leadMs"] as? Double { followRows[0].set(min(max(v, 0), 40)) }
                if let v = f["smooth"] as? Double { followRows[1].set(min(max(v, 0), 0.9)) }
                if let v = f["stopMs"] as? Double { followRows[2].set(min(max(v, 10), 200)) }
            }
            if let r = obj["ripple"] as? [String: Any] {
                if let v = r["on"] as? Bool { rippleOn = v; UserDefaults.standard.set(v, forKey: "rippleOn") }
                if let v = r["radius"] as? Double { rippleRadius = CGFloat(min(max(v, 40), 300)); UserDefaults.standard.set(Double(rippleRadius), forKey: "rippleRadius") }
                if let c = Prefs.color(rgba: r["color"]) { rippleColor = c; UserDefaults.standard.set(Prefs.colorData(c), forKey: "rippleColor") }
                rippleCheck?.state = rippleOn ? .on : .off
                rippleSwatch?.color = rippleColor; rippleSwatch?.alphaValue = rippleOn ? 1 : 0.35
                rippleRow?.show(Double(rippleRadius))
            }
            applyShape()
            refreshControls()
        } catch { alert("読み込めませんでした", error.localizedDescription) }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    @objc func resetScale() { sizeRow.set(1) }
    @objc func resetFollowParams() {
        guard followRows.count == 3 else { return }
        followRows[0].set(0); followRows[1].set(0.4); followRows[2].set(30)
    }

    // MARK: 設定画面

    /// 本体メニューから形を切り替える
    func setShape(_ i: Int) {
        shape = i
        UserDefaults.standard.set(shape, forKey: "shape")
        UserDefaults.standard.set(shape == 1, forKey: "circle")
        applyShape()
        refreshControls()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "カーソル表示の設定"
            w.isReleasedWhenClosed = false

            func swatchView(target: Int) -> SwatchView {
                let v = SwatchView(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
                v.onClick = { [weak self] in self?.openColorPanel(target: target) }
                v.widthAnchor.constraint(equalToConstant: 44).isActive = true
                v.heightAnchor.constraint(equalToConstant: 24).isActive = true
                return v
            }
            func header(_ t: String) -> NSTextField {
                let l = NSTextField(labelWithString: t)
                l.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                l.textColor = .secondaryLabelColor
                return l
            }

            // 形
            shapeControl = NSSegmentedControl(labels: ["矢印", "丸", "本物"], trackingMode: .selectOne, target: self, action: #selector(shapeChanged(_:)))
            let shapeRow = NSStackView(views: [NSTextField(labelWithString: "形"), shapeControl]); shapeRow.spacing = 10
            let shapeNote = NSTextField(labelWithString: "以下の設定は、選んでいる形ごとに別々に保存されます")
            shapeNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize); shapeNote.textColor = .secondaryLabelColor

            // サイズ(現在のサイズ = 1.0)
            sizeRow = ParamRow(label: "サイズ", unit: "×", min: 0.3, max: 4, step: 0.05, fmt: "%.2f", value: Double(cur.scale))
            sizeRow.onChange = { [weak self] v in self?.cur.scale = CGFloat(v); self?.profileChanged() }
            let reset = NSButton(title: "1.0 に戻す", target: self, action: #selector(resetScale))

            // 色・あり/なし
            outlineCheck = NSButton(checkboxWithTitle: "輪郭", target: self, action: #selector(outlineToggled(_:)))
            fillCheck = NSButton(checkboxWithTitle: "本体", target: self, action: #selector(fillToggled(_:)))
            outlineSwatch = swatchView(target: 0)
            fillSwatch = swatchView(target: 1)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let colorRow = NSStackView(views: [reset, spacer, outlineCheck, outlineSwatch, fillCheck, fillSwatch])
            colorRow.spacing = 8
            colorRow.setCustomSpacing(18, after: outlineSwatch)

            widthRow = ParamRow(label: "輪郭の太さ", unit: "pt", min: 0.5, max: 20, step: 0.5, fmt: "%.1f", value: Double(cur.lineWidth))
            widthRow.onChange = { [weak self] v in self?.cur.lineWidth = CGFloat(v); self?.profileChanged() }
            blurRow = ParamRow(label: "ぼかし", unit: "pt", min: 0, max: 10, step: 0.5, fmt: "%.1f", value: Double(cur.blur))
            blurRow.onChange = { [weak self] v in self?.cur.blur = CGFloat(v); self?.profileChanged() }
            opacityRow = ParamRow(label: "不透明度", unit: "", min: 0.1, max: 1, step: 0.05, fmt: "%.2f", value: Double(cur.opacity))
            opacityRow.onChange = { [weak self] v in self?.cur.opacity = CGFloat(v); self?.profileChanged() }

            // 追従(全体共通)
            let leadRow = ParamRow(label: "先読み", unit: "ms", key: "leadMs", min: 0, max: 40, step: 1, fmt: "%.0f", value: Double(lead) * 1000)
            leadRow.onChange = { [weak self] v in self?.lead = CGFloat(v) / 1000 }
            let smoothRow = ParamRow(label: "なめらかさ", unit: "", key: "smooth", min: 0, max: 0.9, step: 0.05, fmt: "%.2f", value: Double(smooth))
            smoothRow.onChange = { [weak self] v in self?.smooth = CGFloat(v) }
            let stopRow = ParamRow(label: "停止判定", unit: "ms", key: "stopMs", min: 10, max: 200, step: 5, fmt: "%.0f", value: stopDelay * 1000)
            stopRow.onChange = { [weak self] v in self?.stopDelay = v / 1000 }
            followRows = [leadRow, smoothRow, stopRow]
            let resetFollow = NSButton(title: "追従を初期値に戻す", target: self, action: #selector(resetFollowParams))

            // 波紋(全体共通)
            rippleCheck = NSButton(checkboxWithTitle: "Command を単独で押すと波紋", target: self, action: #selector(rippleToggled(_:)))
            rippleCheck.state = rippleOn ? .on : .off
            rippleSwatch = swatchView(target: 2)
            rippleSwatch.color = rippleColor
            rippleSwatch.alphaValue = rippleOn ? 1 : 0.35
            let rSpacer = NSView(); rSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let rippleTop = NSStackView(views: [rippleCheck, rSpacer, NSTextField(labelWithString: "色"), rippleSwatch]); rippleTop.spacing = 8
            rippleRow = ParamRow(label: "波紋の大きさ", unit: "pt", key: "rippleRadius", min: 40, max: 300, step: 10, fmt: "%.0f", value: Double(rippleRadius))
            rippleRow.onChange = { [weak self] v in self?.rippleRadius = CGFloat(v) }

            let exportBtn = NSButton(title: "設定を書き出す…", target: self, action: #selector(exportSettings))
            let importBtn = NSButton(title: "設定を読み込む…", target: self, action: #selector(importSettings))
            let moveRow = NSStackView(views: [exportBtn, importBtn]); moveRow.spacing = 8

            mcCheck = NSButton(checkboxWithTitle: "Mission Control / アプリケーション Exposé の表示中は隠す", target: self, action: #selector(mcToggled(_:)))
            mcCheck.state = hideDuringMC ? .on : .off

            let rows: [NSView] = [
                header("形"), shapeRow, shapeNote,
                header("見た目(選んだ形の設定)"), sizeRow.stack, colorRow, widthRow.stack, blurRow.stack, opacityRow.stack,
                header("追従の調整(全体共通 / 先読み 0 = なし)"), leadRow.stack, smoothRow.stack, stopRow.stack, resetFollow,
                header("波紋(全体共通)"), rippleTop, rippleRow.stack,
                header("設定の引っ越し(JSON)"), moveRow,
                mcCheck,
            ]
            let stack = NSStackView(views: rows)
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
            stack.setCustomSpacing(18, after: shapeNote)
            stack.setCustomSpacing(18, after: opacityRow.stack)
            stack.setCustomSpacing(18, after: resetFollow)
            stack.setCustomSpacing(18, after: rippleRow.stack)
            stack.setCustomSpacing(18, after: moveRow)
            stack.translatesAutoresizingMaskIntoConstraints = false
            w.contentView!.addSubview(stack)
            var cons = [
                stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 20),
            ]
            for r in [rippleTop, rippleRow.stack, sizeRow.stack, colorRow, widthRow.stack, blurRow.stack, opacityRow.stack, leadRow.stack, smoothRow.stack, stopRow.stack] {
                cons.append(r.widthAnchor.constraint(equalTo: stack.widthAnchor))
            }
            NSLayoutConstraint.activate(cons)
            w.contentView!.layoutSubtreeIfNeeded()
            w.setContentSize(NSSize(width: 380, height: stack.fittingSize.height + 40))
            w.center()
            settingsWindow = w
            refreshControls()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
