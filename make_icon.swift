import Cocoa

// 使い方: swiftc make_icon.swift -o /tmp/make_icon && /tmp/make_icon <出力.iconset のフォルダ>
// ワンマンカーソルの「ワ」を、丸みを帯びたフォント(ヒラギノ丸ゴ)で大きく描く
func maruFont(_ size: CGFloat) -> NSFont {
    for name in ["HiraMaruProN-W8", "HiraMaruProN-W4", "Hiragino Maru Gothic ProN W8", "Hiragino Maru Gothic ProN W6"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.systemFont(ofSize: size, weight: .heavy)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = CGFloat(px) / 1024
    // 背景: 角丸の四角(macOS のアイコン枠 824pt)に青→紫のグラデーション
    let box = NSRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u)
    let bg = NSBezierPath(roundedRect: box, xRadius: 185*u, yRadius: 185*u)
    NSGradient(starting: NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),
               ending: NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1))!.draw(in: bg, angle: -90)
    // 「ワ」を白で中央に
    let s = "ワ" as NSString
    let font = maruFont(600 * u)
    // 丸ゴは W4 しか無く細く見えるので、輪郭を白で太らせて描く(負の線幅 = 塗り+輪郭)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                .strokeColor: NSColor.white, .strokeWidth: -8.0]
    let ts = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: box.midX - ts.width / 2, y: box.midY - ts.height / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16",16),("16@2x",32),("32",32),("32@2x",64),("128",128),("128@2x",256),("256",256),("256@2x",512),("512",512),("512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"))
}
