import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

// The cursor display part of OneManCursor. Code brought in from AlwaysCursor.
// Handles overlay tracking, shapes, the ripple, and the settings window.
// While control is handed off via cursor sharing, drawing stops based on CursorShare.sessionActiveAway.

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty") func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

let S: CGFloat = 260         // Window side length. The center is the cursor tip (hotspot)
let K0: CGFloat = 0.7425     // Scale factor at size 1.0

// MARK: - Persistence

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

/// Appearance settings per shape (arrow / circle). Saved separately for each shape
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

    /// For JSON export (colors as RGBA numbers)
    func exported() -> [String: Any] {
        ["scale": Double(scale), "outlineOn": outlineOn, "color": Prefs.rgba(color), "lineWidth": Double(lineWidth),
         "blur": Double(blur), "fillOn": fillOn, "fillColor": Prefs.rgba(fillColor), "opacity": Double(opacity)]
    }
    /// JSON import. Missing items keep their current values
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

    /// Use the saved values if any; otherwise carry over the old version's shared settings (scale / color …)
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

// MARK: - Display

/// An arrow shaped like the standard cursor, or a circle. The real cursor is always in front of the window
final class ArrowView: NSView {
    var profile = Profile() { didSet { applyBlur(); needsDisplay = true } }
    var circle = false { didSet { needsDisplay = true } }
    // Lookalike mode: draw the real cursor's image enlarged as is
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
            // Draw the real cursor's image enlarged so that the hotspot is at the center
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
            let r = 28 * K          // A circle centered on the tip (hotspot)
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

// MARK: - Settings window components

/// A color swatch with small rounded corners. Clicking opens the standard color panel
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

/// A single row where the slider and numeric input are linked. If key is set, it is saved to UserDefaults
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
    /// Update only the on-screen display (does not call onChange)
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

// MARK: - App core

final class CursorOverlay: NSObject {
    var showArrow = true
    var overlay: NSWindow!
    var displayLink: AnyObject?     // CADisplayLink on macOS 14 and later, Timer on earlier versions
    var cmdTimer: Timer?            // Check of the Command key (low frequency)
    var lastOrigin = NSPoint(x: -99999, y: -99999)
    var monitors: [Any] = []
    var settingsWindow: NSWindow?

    // For lookahead: the most recent velocity (pt/sec) and the time of the last movement
    var velocity = CGPoint.zero
    var lastPos = NSEvent.mouseLocation
    var lastTime = CACurrentMediaTime()
    var lead = CGFloat(Prefs.double("leadMs", default: 0)) / 1000      // How many seconds ahead to place it (0 = no lookahead)
    var smooth = CGFloat(Prefs.double("smooth", default: 0.4))         // Velocity smoothing (larger = smoother)
    var stopDelay = Prefs.double("stopMs", default: 30) / 1000         // Time after which movement is considered stopped

    // Per-shape settings. 0 = arrow, 1 = circle, 2 = lookalike of the real cursor
    let profiles = [Profile.load("profile.arrow"), Profile.load("profile.circle"), Profile.load("profile.mirror")]
    var shape = UserDefaults.standard.object(forKey: "shape") as? Int ?? (UserDefaults.standard.bool(forKey: "circle") ? 1 : 0)
    var lastCursor: NSCursor?
    var cur: Profile { profiles[shape] }
    var arrowView: ArrowView? { overlay.contentView as? ArrowView }

    // Settings window components
    var shapeControl: NSSegmentedControl!
    var sizeRow: ParamRow!, widthRow: ParamRow!, blurRow: ParamRow!, opacityRow: ParamRow!
    var followRows: [ParamRow] = []
    var outlineCheck: NSButton!, fillCheck: NSButton!
    var outlineSwatch: SwatchView!, fillSwatch: SwatchView!
    var editingTarget = 0           // Target of the color panel: 0 = outline, 1 = body, 2 = ripple

    // Ripple (lone Command tap)
    var rippleOn = UserDefaults.standard.object(forKey: "rippleOn") as? Bool ?? true
    var rippleRadius = CGFloat(Prefs.double("rippleRadius", default: 110))
    var rippleColor = Prefs.color(from: UserDefaults.standard.data(forKey: "rippleColor")) ?? .systemRed
    var rippleWindow: NSWindow?
    var rippleHide: DispatchWorkItem?
    var cmdDownAt: CFTimeInterval?
    var cmdClean = false
    var rippleCheck: NSButton!, rippleSwatch: SwatchView!, rippleRow: ParamRow!

    // Hide during Mission Control / App Exposé (optional setting)
    var hideDuringMC = UserDefaults.standard.bool(forKey: "hideDuringMC")
    var mcActive = false
    var mcPollCount = 0
    var mcCheck: NSButton!

    func start() {
        _ = CGSSetConnectionProperty(CGSMainConnectionID(), CGSMainConnectionID(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        // Initial size in lookalike mode is 2× (the same size as the real cursor would be too small)
        if UserDefaults.standard.dictionary(forKey: "profile.mirror") == nil { profiles[2].scale = 2 }

        overlay = NSWindow(contentRect: NSRect(x: 0, y: 0, width: S, height: S), styleMask: .borderless, backing: .buffered, defer: false)
        overlay.backgroundColor = .clear; overlay.isOpaque = false; overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .screenSaver
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlay.contentView = ArrowView(frame: NSRect(x: 0, y: 0, width: S, height: S))
        applyShape()

        // Follow the instant mouse movement arrives (event-driven)
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.wake(); self?.follow() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.wake(); self?.follow(); return e }) { monitors.append(m) }
        // Also sync with display refresh (120 times/sec on a 120Hz display)
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

    // MARK: Tracking

    @objc func cmdTick() {
        checkCommand()
        updateMirrorCursor()
        // Mission Control detection is checked at a reduced rate (about 5 times/sec)
        if hideDuringMC || mcActive {
            mcPollCount += 1
            if mcPollCount >= 6 { mcPollCount = 0; checkMissionControl() }
        }
    }

    /// Whether Mission Control / App Exposé is currently showing
    /// There is no official way to tell, so estimate from whether the Dock has a full-screen-size window
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
            // When it comes back, resume tracking from the current position
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

    /// Display-refresh sync runs only while moving (it rests while stopped to save power)
    func wake() {
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.isPaused = false }
    }
    func sleepLink() {
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.isPaused = true }
    }

    @objc func tick() {
        follow()
        // Rest once it has been stopped long enough (leave margin for lookahead convergence and stop detection)
        if CACurrentMediaTime() - lastTime > stopDelay + 0.15 { sleepLink() }
    }

    /// Detect a lone Command tap (pressed and released quickly, with no other keys or clicks in between) and show a ripple
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
        // Three rings shrinking from the outside toward the center (like Windows' "Show location of pointer when I press CTRL")
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
        // Don't draw while control is handed off via cursor sharing (drawing would create a double cursor)
        if CursorShare.shared.sessionActiveAway {
            if overlay.isVisible { overlay.orderOut(nil) }
            return
        }
        let now = CACurrentMediaTime()
        let p = NSEvent.mouseLocation
        let dt = now - lastTime
        if p != lastPos, dt > 0.0005 {
            // Estimate velocity with slight smoothing
            let v = CGPoint(x: (p.x - lastPos.x) / dt, y: (p.y - lastPos.y) / dt)
            velocity = CGPoint(x: velocity.x * smooth + v.x * (1 - smooth), y: velocity.y * smooth + v.y * (1 - smooth))
            lastPos = p; lastTime = now
        } else if now - lastTime > stopDelay {
            velocity = .zero            // Stop lookahead once stopped (prevents overshoot)
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

    // MARK: Applying shape and appearance

    /// Apply the selected shape's settings to the display
    func applyShape() {
        guard let v = arrowView else { return }
        v.circle = shape == 1
        v.mirror = shape == 2
        v.profile = cur
        overlay.alphaValue = cur.opacity
        if shape == 2 { lastCursor = nil; updateMirrorCursor() }
    }
    /// Common handling when the appearance changes (apply and save)
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

    /// For lookalike mode: capture the real cursor currently shown and redraw with it
    func updateMirrorCursor() {
        guard shape == 2, let v = arrowView else { return }
        let c = NSCursor.currentSystem ?? NSCursor.arrow
        if c !== lastCursor {
            lastCursor = c
            v.mirrorImage = c.image
            v.mirrorHotSpot = c.hotSpot
        }
    }

    /// Show the selected shape's settings in the settings window
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
        // Lookalike enlarges the real cursor image as is, so color, outline thickness, and blur
        // have no effect. Disable the settings that have no effect (size and opacity do take effect)
        let mirror = shape == 2
        outlineCheck.isEnabled = !mirror
        fillCheck.isEnabled = !mirror
        widthRow.slider.isEnabled = !mirror; widthRow.field.isEnabled = !mirror
        blurRow.slider.isEnabled = !mirror; blurRow.field.isEnabled = !mirror
        if mirror { outlineSwatch.alphaValue = 0.35; fillSwatch.alphaValue = 0.35 }
    }

    // MARK: Color

    func openColorPanel(target: Int) {
        if shape == 2, target != 2 { return }   // Color has no effect in lookalike mode
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
    // MARK: Settings export / import

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
        } catch { alert("Could not export", error.localizedDescription) }
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
                alert("Could not import", "This does not appear to be an AlwaysCursor settings file."); return
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
        } catch { alert("Could not import", error.localizedDescription) }
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    @objc func resetScale() { sizeRow.set(1) }
    @objc func resetFollowParams() {
        guard followRows.count == 3 else { return }
        followRows[0].set(0); followRows[1].set(0.4); followRows[2].set(30)
    }

    // MARK: Settings window

    /// Switch the shape from the main menu
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
            w.title = "Cursor Display Settings"
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

            // Shape
            shapeControl = NSSegmentedControl(labels: ["Arrow", "Circle", "Real"], trackingMode: .selectOne, target: self, action: #selector(shapeChanged(_:)))
            let shapeRow = NSStackView(views: [NSTextField(labelWithString: "Shape"), shapeControl]); shapeRow.spacing = 10
            let shapeNote = NSTextField(labelWithString: "The settings below are saved separately for each selected shape")
            shapeNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize); shapeNote.textColor = .secondaryLabelColor

            // Size (current size = 1.0)
            sizeRow = ParamRow(label: "Size", unit: "×", min: 0.3, max: 4, step: 0.05, fmt: "%.2f", value: Double(cur.scale))
            sizeRow.onChange = { [weak self] v in self?.cur.scale = CGFloat(v); self?.profileChanged() }
            let reset = NSButton(title: "Reset to 1.0", target: self, action: #selector(resetScale))

            // Color, on/off
            outlineCheck = NSButton(checkboxWithTitle: "Outline", target: self, action: #selector(outlineToggled(_:)))
            fillCheck = NSButton(checkboxWithTitle: "Body", target: self, action: #selector(fillToggled(_:)))
            outlineSwatch = swatchView(target: 0)
            fillSwatch = swatchView(target: 1)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let colorRow = NSStackView(views: [reset, spacer, outlineCheck, outlineSwatch, fillCheck, fillSwatch])
            colorRow.spacing = 8
            colorRow.setCustomSpacing(18, after: outlineSwatch)

            widthRow = ParamRow(label: "Outline width", unit: "pt", min: 0.5, max: 20, step: 0.5, fmt: "%.1f", value: Double(cur.lineWidth))
            widthRow.onChange = { [weak self] v in self?.cur.lineWidth = CGFloat(v); self?.profileChanged() }
            blurRow = ParamRow(label: "Blur", unit: "pt", min: 0, max: 10, step: 0.5, fmt: "%.1f", value: Double(cur.blur))
            blurRow.onChange = { [weak self] v in self?.cur.blur = CGFloat(v); self?.profileChanged() }
            opacityRow = ParamRow(label: "Opacity", unit: "", min: 0.1, max: 1, step: 0.05, fmt: "%.2f", value: Double(cur.opacity))
            opacityRow.onChange = { [weak self] v in self?.cur.opacity = CGFloat(v); self?.profileChanged() }

            // Tracking (shared by all shapes)
            let leadRow = ParamRow(label: "Lookahead", unit: "ms", key: "leadMs", min: 0, max: 40, step: 1, fmt: "%.0f", value: Double(lead) * 1000)
            leadRow.onChange = { [weak self] v in self?.lead = CGFloat(v) / 1000 }
            let smoothRow = ParamRow(label: "Smoothness", unit: "", key: "smooth", min: 0, max: 0.9, step: 0.05, fmt: "%.2f", value: Double(smooth))
            smoothRow.onChange = { [weak self] v in self?.smooth = CGFloat(v) }
            let stopRow = ParamRow(label: "Stop detection", unit: "ms", key: "stopMs", min: 10, max: 200, step: 5, fmt: "%.0f", value: stopDelay * 1000)
            stopRow.onChange = { [weak self] v in self?.stopDelay = v / 1000 }
            followRows = [leadRow, smoothRow, stopRow]
            let resetFollow = NSButton(title: "Reset tracking to defaults", target: self, action: #selector(resetFollowParams))

            // Ripple (shared by all shapes)
            rippleCheck = NSButton(checkboxWithTitle: "Ripple on a lone Command press", target: self, action: #selector(rippleToggled(_:)))
            rippleCheck.state = rippleOn ? .on : .off
            rippleSwatch = swatchView(target: 2)
            rippleSwatch.color = rippleColor
            rippleSwatch.alphaValue = rippleOn ? 1 : 0.35
            let rSpacer = NSView(); rSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let rippleTop = NSStackView(views: [rippleCheck, rSpacer, NSTextField(labelWithString: "Color"), rippleSwatch]); rippleTop.spacing = 8
            rippleRow = ParamRow(label: "Ripple size", unit: "pt", key: "rippleRadius", min: 40, max: 300, step: 10, fmt: "%.0f", value: Double(rippleRadius))
            rippleRow.onChange = { [weak self] v in self?.rippleRadius = CGFloat(v) }

            let exportBtn = NSButton(title: "Export Settings…", target: self, action: #selector(exportSettings))
            let importBtn = NSButton(title: "Import Settings…", target: self, action: #selector(importSettings))
            let moveRow = NSStackView(views: [exportBtn, importBtn]); moveRow.spacing = 8

            mcCheck = NSButton(checkboxWithTitle: "Hide while Mission Control / App Exposé is showing", target: self, action: #selector(mcToggled(_:)))
            mcCheck.state = hideDuringMC ? .on : .off

            let rows: [NSView] = [
                header("Shape"), shapeRow, shapeNote,
                header("Appearance (settings for the selected shape)"), sizeRow.stack, colorRow, widthRow.stack, blurRow.stack, opacityRow.stack,
                header("Tracking adjustment (shared by all shapes / lookahead 0 = off)"), leadRow.stack, smoothRow.stack, stopRow.stack, resetFollow,
                header("Ripple (shared by all shapes)"), rippleTop, rippleRow.stack,
                header("Move settings (JSON)"), moveRow,
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
