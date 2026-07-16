import AppKit

// Renders a 1024×1024 app icon PNG and packages it as AppIcon.icns.
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = CGRect(x: 0, y: 0, width: size, height: size)

// Rounded background with a diagonal gradient.
let path = CGPath(roundedRect: rect.insetBy(dx: 40, dy: 40), cornerWidth: 200, cornerHeight: 200, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.42, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.30, green: 0.52, blue: 0.86, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Three stacked "layers" motif (the personal OS layers).
func layer(_ y: CGFloat, _ alpha: CGFloat) {
    let w: CGFloat = 470, h: CGFloat = 120
    let r = CGRect(x: (CGFloat(size) - w)/2, y: y, width: w, height: h)
    let p = CGPath(roundedRect: r, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.addPath(p)
    ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
    ctx.fillPath()
}
layer(300, 0.95)
layer(452, 0.72)
layer(604, 0.5)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr); exit(1)
}
let dist = "dist"
try? FileManager.default.createDirectory(atPath: "\(dist)/AppIcon.iconset", withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "\(dist)/icon-1024.png"))
print("wrote dist/icon-1024.png")
