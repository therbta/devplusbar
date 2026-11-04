#!/usr/bin/env swift
//
// Dev+ Bar uygulama ikonunu uretir.
//
// Harici bir cizim araci yerine AppKit kullaniliyor: makinede zaten var,
// her boyut tam kontrolle ciziliyor ve sonuc dogrudan .iconset klasoru.
//
//   swift Tools/makeicon.swift  ->  build/Dev+ Bar.iconset
//   iconutil -c icns build/Dev+ Bar.iconset -o Resources/Dev+ Bar.icns
//
import AppKit

// MARK: - Palet

let primary     = NSColor(srgbRed: 0xFC/255.0, green: 0x42/255.0, blue: 0x06/255.0, alpha: 1)  // #FC4206
let primaryHot  = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.16, alpha: 1)
let primaryDeep = NSColor(srgbRed: 0.80, green: 0.18, blue: 0.00, alpha: 1)
let ink         = NSColor(srgbRed: 0.10, green: 0.05, blue: 0.03, alpha: 1)

// MARK: - Cizim

/// macOS ikonlari kenarlarda seffaf pay birakir; 1024'luk tuvalde
/// gorunur alan ~824 px olur.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)

    let inset = size * 0.098
    let plateRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plateRect.width * 0.2237
    let s = plateRect.width

    // Turuncu zemin
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: radius, yRadius: radius)
    context.saveGState()
    plate.addClip()
    NSGradient(colors: [primaryHot, primary, primaryDeep])!.draw(in: plateRect, angle: -70)

    // Ustte menu cubugu seridi — uygulamanin yasadigi yer
    let barH = s * 0.13
    let bar = CGRect(x: plateRect.minX, y: plateRect.maxY - barH, width: s, height: barH)
    NSColor(white: 0, alpha: 0.18).setFill()
    NSBezierPath(rect: bar).fill()
    // Menu cubugunda "aktif" ikon noktasi
    NSColor(white: 1, alpha: 0.95).setFill()
    let pill = CGRect(x: plateRect.maxX - s * 0.27, y: bar.midY - s * 0.022, width: s * 0.13, height: s * 0.044)
    NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    NSColor(white: 1, alpha: 0.45).setFill()
    for i in 0..<2 {
        let d = s * 0.044
        let x = plateRect.minX + s * 0.12 + CGFloat(i) * s * 0.075
        NSBezierPath(ovalIn: CGRect(x: x, y: bar.midY - d / 2, width: d, height: d)).fill()
    }

    // Ust kenar isigi
    let hl = NSBezierPath(roundedRect: plateRect.insetBy(dx: size * 0.004, dy: size * 0.004), xRadius: radius, yRadius: radius)
    hl.lineWidth = size * 0.006
    NSColor(white: 1, alpha: 0.22).setStroke()
    hl.stroke()
    context.restoreGState()

    // MARK: Diff isareti
    //
    // Diff'in eklenen/silinen isaretleri: "+" ustte, "−" altta.

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                      color: NSColor(white: 0, alpha: 0.28).cgColor)
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    // Ustte "+", altta "−": klasik diff isareti, ortalanmis
    let cx = plateRect.midX
    let bigStroke = s * 0.1
    let half = s * 0.16
    let plusY = plateRect.midY + s * 0.06
    let minusY = plateRect.midY - s * 0.27
    func rule(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = bigStroke
        p.lineCapStyle = .round
        p.move(to: CGPoint(x: x0, y: y0)); p.line(to: CGPoint(x: x1, y: y1))
        NSColor.white.setStroke(); p.stroke()
    }
    rule(cx - half, plusY, cx + half, plusY)
    rule(cx, plusY - half, cx, plusY + half)
    rule(cx - half, minusY, cx + half, minusY)

    context.endTransparencyLayer()
    context.restoreGState()

    return image
}

// MARK: - Yazma

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/Dev+ Bar.iconset"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

// iconutil'in bekledigi tam dosya adlari
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",     32),
    ("icon_32x32",      32), ("icon_32x32@2x",     64),
    ("icon_128x128",   128), ("icon_128x128@2x",  256),
    ("icon_256x256",   256), ("icon_256x256@2x",  512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let data = png(NSImage(), variant.pixels)
    let path = "\(outputDirectory)/\(variant.name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("  \(variant.name).png  (\(variant.pixels)px, \(data.count / 1024) KB)")
}
print("iconset hazir: \(outputDirectory)")
