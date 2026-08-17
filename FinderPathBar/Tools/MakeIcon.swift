import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillGradient(_ rect: NSRect, colors: [NSColor], angle: CGFloat) {
    NSGradient(colors: colors)?.draw(in: rect, angle: angle)
}

image.lockFocus()
let fullRect = NSRect(origin: .zero, size: canvas)
NSColor.clear.setFill()
fullRect.fill()

NSGraphicsContext.saveGraphicsState()
let appShadow = NSShadow()
appShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
appShadow.shadowBlurRadius = 34
appShadow.shadowOffset = NSSize(width: 0, height: -18)
appShadow.set()

let tileRect = NSRect(x: 96, y: 96, width: 832, height: 832)
let tilePath = rounded(tileRect, 180)
tilePath.addClip()
fillGradient(
    tileRect,
    colors: [
        NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.74, blue: 1.00, alpha: 1)
    ],
    angle: 45
)
NSGraphicsContext.restoreGraphicsState()

let highlight = rounded(NSRect(x: 142, y: 584, width: 740, height: 290), 132)
NSColor.white.withAlphaComponent(0.16).setFill()
highlight.fill()

let split = NSBezierPath()
split.move(to: NSPoint(x: 512, y: 172))
split.line(to: NSPoint(x: 512, y: 842))
split.lineWidth = 18
NSColor.white.withAlphaComponent(0.30).setStroke()
split.stroke()

let leftEye = rounded(NSRect(x: 305, y: 590, width: 70, height: 70), 28)
let rightEye = rounded(NSRect(x: 648, y: 590, width: 70, height: 70), 28)
NSColor.white.withAlphaComponent(0.96).setFill()
leftEye.fill()
rightEye.fill()

let smile = NSBezierPath()
smile.move(to: NSPoint(x: 330, y: 405))
smile.curve(to: NSPoint(x: 694, y: 405), controlPoint1: NSPoint(x: 424, y: 315), controlPoint2: NSPoint(x: 600, y: 315))
smile.lineWidth = 30
smile.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.95).setStroke()
smile.stroke()

NSGraphicsContext.saveGraphicsState()
let barShadow = NSShadow()
barShadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
barShadow.shadowBlurRadius = 18
barShadow.shadowOffset = NSSize(width: 0, height: -8)
barShadow.set()

let addressRect = NSRect(x: 184, y: 478, width: 656, height: 146)
let addressPath = rounded(addressRect, 50)
NSColor.white.setFill()
addressPath.fill()
NSGraphicsContext.restoreGraphicsState()

let pill = rounded(NSRect(x: 252, y: 530, width: 438, height: 42), 21)
NSColor(calibratedRed: 0.06, green: 0.30, blue: 0.68, alpha: 1).setFill()
pill.fill()

for x in [724, 768] {
    let node = rounded(NSRect(x: CGFloat(x), y: 530, width: 42, height: 42), 21)
    NSColor(calibratedRed: 0.06, green: 0.30, blue: 0.68, alpha: 1).setFill()
    node.fill()
}

let topLine = NSBezierPath()
topLine.move(to: NSPoint(x: 230, y: 690))
topLine.line(to: NSPoint(x: 794, y: 690))
topLine.lineWidth = 18
topLine.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.44).setStroke()
topLine.stroke()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon")
}

try png.write(to: URL(fileURLWithPath: outputPath))
