import AppKit

// Original document artwork: a folded sheet, a zipper, and a format label.
// Rendered from vector paths; no system or third-party artwork is bundled.
guard CommandLine.arguments.count == 4 else {
    fputs("Usage: swift GenerateDocumentIcons.swift Info.plist ResourcesDirectory PreviewDirectory\n", stderr)
    exit(1)
}
let plistURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let previews = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
let documentTypes = plist["CFBundleDocumentTypes"] as! [[String: Any]]
var icons: [String: String] = [:]
for documentType in documentTypes {
    guard let name = documentType["CFBundleTypeIconFile"] as? String,
          let extensions = documentType["CFBundleTypeExtensions"] as? [String],
          let first = extensions.first else { continue }
    let label = first.uppercased()
    precondition(icons[name] == nil || icons[name] == label, "Conflicting document icon labels")
    icons[name] = label
}
precondition(!icons.isEmpty, "No document icons declared")

func gray(_ value: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: value, green: value, blue: value, alpha: alpha)
}

func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func render(label: String, points: Int, scale: Int) throws -> Data {
    let pixels = points * scale
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                       pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "SevenZipDocumentIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: 202, y: 104))
    paper.line(to: NSPoint(x: 822, y: 104))
    paper.curve(to: NSPoint(x: 848, y: 130), controlPoint1: NSPoint(x: 837, y: 104), controlPoint2: NSPoint(x: 848, y: 115))
    paper.line(to: NSPoint(x: 848, y: 744))
    paper.line(to: NSPoint(x: 648, y: 944))
    paper.line(to: NSPoint(x: 202, y: 944))
    paper.curve(to: NSPoint(x: 176, y: 918), controlPoint1: NSPoint(x: 187, y: 944), controlPoint2: NSPoint(x: 176, y: 933))
    paper.line(to: NSPoint(x: 176, y: 130))
    paper.curve(to: NSPoint(x: 202, y: 104), controlPoint1: NSPoint(x: 176, y: 115), controlPoint2: NSPoint(x: 187, y: 104))
    paper.close()

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = gray(0, alpha: 0.19)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    gray(0.98).setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [gray(0.94), gray(1)])!.draw(in: paper, angle: 90)
    gray(0.60, alpha: 0.22).setStroke()
    paper.lineWidth = 2
    paper.stroke()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 648, y: 944))
    fold.line(to: NSPoint(x: 648, y: 770))
    fold.curve(to: NSPoint(x: 674, y: 744), controlPoint1: NSPoint(x: 648, y: 755), controlPoint2: NSPoint(x: 659, y: 744))
    fold.line(to: NSPoint(x: 848, y: 744))
    fold.close()
    NSGraphicsContext.saveGraphicsState()
    paper.addClip()
    let foldShadow = NSShadow()
    foldShadow.shadowColor = gray(0, alpha: 0.12)
    foldShadow.shadowBlurRadius = 12
    foldShadow.shadowOffset = NSSize(width: -3, height: -5)
    foldShadow.set()
    gray(0.94).setFill()
    fold.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [gray(0.88), gray(0.99)])!.draw(in: fold, angle: 38)

    // A simple pull and alternating teeth remain recognizable at list sizes.
    let ink = gray(points <= 32 ? 0.56 : 0.65)
    let pull = NSBezierPath(roundedRect: NSRect(x: 463, y: 718, width: 98, height: 188), xRadius: 43, yRadius: 43)
    pull.append(NSBezierPath(roundedRect: NSRect(x: 488, y: 743, width: 48, height: 68), xRadius: 22, yRadius: 22))
    pull.windingRule = .evenOdd
    ink.setFill()
    pull.fill()
    let teeth = points <= 16 ? 4 : 5
    for index in 0..<teeth {
        let x: CGFloat = index.isMultiple(of: 2) ? 466 : 504
        rounded(NSRect(x: x, y: CGFloat(667 - index * 40), width: 58, height: 27), radius: 12, color: ink)
    }

    // At very small sizes the zipper carries the identity; the filename
    // already supplies the extension without squeezing in unreadable text.
    if points >= 64 {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: label.count > 4 ? 96 : 112, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: gray(0.64), .paragraphStyle: paragraph
        ]
        (label as NSString).draw(in: NSRect(x: 220, y: 147, width: 584, height: 142), withAttributes: attributes)
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SevenZipDocumentIcon", code: 2)
    }
    return png
}

func bigEndian(_ value: Int) -> Data {
    var encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}
let representations: [(points: Int, scale: Int, type: String)] = [
    (16, 1, "icp4"), (16, 2, "ic11"), (32, 1, "icp5"), (32, 2, "ic12"),
    (128, 1, "ic07"), (128, 2, "ic13"), (256, 1, "ic08"), (256, 2, "ic14"),
    (512, 1, "ic09"), (512, 2, "ic10")
]
for (name, label) in icons.sorted(by: { $0.key < $1.key }) {
    var elements = Data()
    for representation in representations {
        let png = try render(label: label, points: representation.points, scale: representation.scale)
        elements.append(contentsOf: representation.type.utf8)
        elements.append(bigEndian(png.count + 8))
        elements.append(png)
        if representation.points == 128 && representation.scale == 2 {
            try png.write(to: previews.appendingPathComponent(name + ".png"))
        }
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndian(elements.count + 8))
    icns.append(elements)
    let output = destination.appendingPathComponent(name + ".icns")
    try icns.write(to: output)
    guard let image = NSImage(contentsOf: output), image.isValid else {
        throw NSError(domain: "SevenZipDocumentIcon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid document icon: \(name)"])
    }
}
print("Generated \(icons.count) archive document icons")
