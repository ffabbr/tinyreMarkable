// Generates AppIcon.icns: the reMarkable logo (same paths as the menu bar icon)
// centered on a #f9f6f1 rounded-rectangle, in all macOS icon sizes.
// Usage: swift make_icon.swift <output.icns>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

// Background colour #f9f6f1
let bg = NSColor(red: 0xF9/255.0, green: 0xF6/255.0, blue: 0xF1/255.0, alpha: 1)
let fg = NSColor.black

/// Build the reMarkable logo path in a 16×16 (SVG, y-down) coordinate space.
func logoPath() -> NSBezierPath {
    let p = NSBezierPath()
    // Upper-right "fold".
    p.move(to: NSPoint(x: 8, y: 8))
    p.curve(to: NSPoint(x: 12.1435, y: 6.4616), controlPoint1: NSPoint(x: 8.82048, y: 7.2616), controlPoint2: NSPoint(x: 10.6051, y: 6.4616))
    p.curve(to: NSPoint(x: 16, y: 8), controlPoint1: NSPoint(x: 13.4154, y: 6.4616), controlPoint2: NSPoint(x: 14.7486, y: 6.91296))
    p.line(to: NSPoint(x: 16, y: 0.43072))
    p.curve(to: NSPoint(x: 13.7026, y: 0), controlPoint1: NSPoint(x: 15.2205, y: 0.14352), controlPoint2: NSPoint(x: 14.441, y: 0))
    p.curve(to: NSPoint(x: 8, y: 7.87696), controlPoint1: NSPoint(x: 10.5846, y: 0), controlPoint2: NSPoint(x: 8, y: 2.56416))
    p.line(to: NSPoint(x: 8, y: 8))
    p.close()
    // Lower-left triangle.
    p.move(to: NSPoint(x: 8, y: 16))
    p.line(to: NSPoint(x: 8, y: 8))
    p.line(to: NSPoint(x: 0, y: 0))
    p.line(to: NSPoint(x: 0, y: 8))
    p.line(to: NSPoint(x: 8, y: 16))
    p.close()
    return p
}

func renderPNG(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded "squircle" plate with a small transparent margin, per macOS icon grid.
    let margin = s * 0.085
    let plate = NSRect(x: margin, y: margin, width: s - 2*margin, height: s - 2*margin)
    let radius = plate.width * 0.2237
    let rr = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    bg.setFill()
    rr.fill()

    // Logo centered, ~46% of plate, drawn in a y-down (flipped) transform so SVG coords map directly.
    let logoBox = plate.width * 0.46
    let scale = logoBox / 16.0
    let originX = plate.midX - logoBox/2
    let originY = plate.midY + logoBox/2 // top of glyph; we flip y below

    let t = NSAffineTransform()
    t.translateX(by: originX, yBy: originY)
    t.scaleX(by: scale, yBy: -scale) // flip y so the SVG (y-down) path is upright
    let path = logoPath()
    path.transform(using: t as AffineTransform)
    fg.setFill()
    path.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Build .iconset then convert with iconutil.
let fm = FileManager.default
let iconset = (outPath as NSString).deletingPathExtension + ".iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let specs: [(name: String, size: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",   32),
    ("icon_32x32",      32), ("icon_32x32@2x",   64),
    ("icon_128x128",   128), ("icon_128x128@2x",256),
    ("icon_256x256",   256), ("icon_256x256@2x",512),
    ("icon_512x512",   512), ("icon_512x512@2x",1024),
]
for spec in specs {
    let data = renderPNG(size: spec.size)
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(spec.name).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset, "-o", outPath]
try! proc.run()
proc.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(proc.terminationStatus == 0 ? "wrote \(outPath)" : "iconutil failed")
