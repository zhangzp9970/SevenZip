import AppKit

// Original vector artwork, rendered locally with macOS frameworks.
// No downloaded assets or design-tool dependencies are required.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift GenerateIcon.swift /path/to/AppIcon.iconset /path/to/AppIcon.icns\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func fill(_ rect: NSRect, radius: CGFloat, with shade: NSColor) {
    shade.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func render(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                       pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "SevenZipIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let plate = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860),
                            xRadius: 192, yRadius: 192)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.02, 0.12, 0.30, 0.28)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    shadow.set()
    color(0.05, 0.38, 0.88).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.04, 0.30, 0.80), color(0.12, 0.63, 1.00)])!
        .draw(in: plate, angle: 72)

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    let glow = NSBezierPath(ovalIn: NSRect(x: -60, y: 550, width: 1030, height: 670))
    color(1, 1, 1, 0.07).setFill()
    glow.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let boxShadow = NSShadow()
    boxShadow.shadowColor = color(0.01, 0.16, 0.42, 0.24)
    boxShadow.shadowBlurRadius = 28
    boxShadow.shadowOffset = NSSize(width: 0, height: -19)
    boxShadow.set()
    fill(NSRect(x: 222, y: 228, width: 580, height: 560), radius: 66,
         with: color(0.94, 0.97, 1.00))
    NSGraphicsContext.restoreGraphicsState()
    let box = NSBezierPath(roundedRect: NSRect(x: 222, y: 228, width: 580, height: 560),
                          xRadius: 66, yRadius: 66)
    NSGradient(colors: [color(0.80, 0.89, 0.98), color(0.98, 0.99, 1.00)])!
        .draw(in: box, angle: 90)

    // A slim lid and a geometric 7 remain readable at Finder sidebar sizes.
    fill(NSRect(x: 202, y: 700, width: 620, height: 104), radius: 30,
         with: color(0.98, 0.99, 1.00))
    fill(NSRect(x: 236, y: 687, width: 552, height: 13), radius: 5,
         with: color(0.32, 0.52, 0.78, 0.22))
    let seven = NSBezierPath()
    seven.move(to: NSPoint(x: 301, y: 606))
    seven.line(to: NSPoint(x: 480, y: 606))
    seven.line(to: NSPoint(x: 480, y: 552))
    seven.line(to: NSPoint(x: 388, y: 364))
    seven.line(to: NSPoint(x: 316, y: 364))
    seven.line(to: NSPoint(x: 409, y: 547))
    seven.line(to: NSPoint(x: 301, y: 547))
    seven.close()
    color(0.03, 0.28, 0.68).setFill()
    seven.fill()

    // The zipper is offset to the right, leaving the numeral uncluttered.
    fill(NSRect(x: 576, y: 229, width: 91, height: 575), radius: 10,
         with: color(0.04, 0.35, 0.78))
    for index in 0..<10 {
        let y = CGFloat(286 + index * 43)
        fill(NSRect(x: 582, y: y, width: 35, height: 21), radius: 5,
             with: color(0.86, 0.94, 1.00))
        fill(NSRect(x: 626, y: y + 17, width: 35, height: 21), radius: 5,
             with: color(0.86, 0.94, 1.00))
    }
    fill(NSRect(x: 563, y: 695, width: 116, height: 105), radius: 27,
         with: color(0.02, 0.23, 0.58))
    fill(NSRect(x: 584, y: 648, width: 74, height: 104), radius: 23,
         with: color(0.95, 0.98, 1.00))
    fill(NSRect(x: 604, y: 671, width: 34, height: 53), radius: 11,
         with: color(0.04, 0.31, 0.72))

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SevenZipIcon", code: 2)
    }
    return data
}

func bigEndian(_ value: Int) -> Data {
    var encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

// Modern ICNS elements contain PNG payloads. Writing the container directly
// keeps icon generation self-contained and makes every representation explicit.
let representations: [(size: Int, scale: Int, type: String)] = [
    (16, 1, "icp4"), (16, 2, "ic11"),
    (32, 1, "icp5"), (32, 2, "ic12"),
    (128, 1, "ic07"), (128, 2, "ic13"),
    (256, 1, "ic08"), (256, 2, "ic14"),
    (512, 1, "ic09"), (512, 2, "ic10")
]
var elements = Data()
for item in representations {
    let suffix = item.scale == 2 ? "@2x" : ""
    let filename = "icon_\(item.size)x\(item.size)\(suffix).png"
    let png = try render(pixels: item.size * item.scale)
    try png.write(to: destination.appendingPathComponent(filename))
    elements.append(contentsOf: item.type.utf8)
    elements.append(bigEndian(png.count + 8))
    elements.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(elements.count + 8))
icns.append(elements)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try icns.write(to: output)
guard let image = NSImage(contentsOf: output), image.isValid else {
    throw NSError(domain: "SevenZipIcon", code: 3,
                  userInfo: [NSLocalizedDescriptionKey: "Generated icon could not be loaded by AppKit"])
}
