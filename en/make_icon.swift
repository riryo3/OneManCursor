import Cocoa

// Usage: swiftc make_icon.swift -o /tmp/make_icon && /tmp/make_icon <output .iconset folder>
// Draw a large "ワ" for OneManCursor in a rounded font (Hiragino Maru Gothic)
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
    // Background: rounded square (macOS icon frame, 824pt) with a blue→purple gradient
    let box = NSRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u)
    let bg = NSBezierPath(roundedRect: box, xRadius: 185*u, yRadius: 185*u)
    NSGradient(starting: NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),
               ending: NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1))!.draw(in: bg, angle: -90)
    // Draw the "ワ" in white, centered
    let s = "ワ" as NSString
    let font = maruFont(600 * u)
    // The rounded font only has W4 and looks thin, so thicken it with a white outline (negative stroke width = fill + outline)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white,
                                                .strokeColor: NSColor.white, .strokeWidth: -8.0]
    let ts = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: box.midX - ts.width / 2, y: box.midY - ts.height / 2), withAttributes: attrs)
    // Burn the build number into the bottom right (only when specified)
    if !badge.isEmpty {
        let bfont = NSFont.systemFont(ofSize: 190 * u, weight: .heavy)
        let battrs: [NSAttributedString.Key: Any] = [.font: bfont, .foregroundColor: NSColor.white]
        let bs = badge as NSString
        let bts = bs.size(withAttributes: battrs)
        let pill = NSRect(x: box.maxX - bts.width - 110 * u, y: box.minY + 34 * u,
                          width: bts.width + 56 * u, height: bts.height + 30 * u)
        NSColor(calibratedWhite: 0, alpha: 0.30).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        bs.draw(at: NSPoint(x: pill.midX - bts.width / 2, y: pill.midY - bts.height / 2), withAttributes: battrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Build number (optional): burned small into the bottom right of the icon, to tell old copies apart at a glance
let badge = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16",16),("16@2x",32),("32",32),("32@2x",64),("128",128),("128@2x",256),("256",256),("256@2x",512),("512",512),("512@2x",1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name.replacingOccurrences(of: "@2x", with: ""))x\(name.replacingOccurrences(of: "@2x", with: ""))\(name.contains("@2x") ? "@2x" : "").png"))
}
