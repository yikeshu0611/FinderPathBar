import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)

image.lockFocus()
let full = NSRect(origin: .zero, size: canvas)
NSColor.clear.setFill()
full.fill()

let tile = NSRect(x: 96, y: 96, width: 832, height: 832)
let path = NSBezierPath(roundedRect: tile, xRadius: 180, yRadius: 180)
path.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.85, alpha: 1)
])?.draw(in: tile, angle: 90)

// Folder shape
let folder = NSBezierPath()
folder.move(to: NSPoint(x: 260, y: 300))
folder.line(to: NSPoint(x: 260, y: 620))
folder.line(to: NSPoint(x: 400, y: 620))
folder.line(to: NSPoint(x: 460, y: 680))
folder.line(to: NSPoint(x: 760, y: 680))
folder.line(to: NSPoint(x: 760, y: 300))
folder.close()
NSColor.white.withAlphaComponent(0.92).setFill()
folder.fill()

let tab = NSBezierPath(roundedRect: NSRect(x: 300, y: 420, width: 420, height: 36), xRadius: 10, yRadius: 10)
NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.88, alpha: 1).setFill()
tab.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode icon\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
