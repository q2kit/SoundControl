// Draws the SoundControl app icon: a small mixing desk with three faders.
// Usage: swift make-icon.swift <output.png>   (renders 1024×1024)
import AppKit
import SwiftUI

let size: CGFloat = 1024
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func withShadow(_ offset: CGSize, _ blur: CGFloat, _ c: NSColor, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow(); s.shadowOffset = offset; s.shadowBlurRadius = blur; s.shadowColor = c; s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

/// The squircle macOS uses for icons (continuous corners), not a plain rounded rectangle.
func squircle(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(cgPath: Path(roundedRect: r, cornerRadius: radius, style: .continuous).cgPath)
}

// Body: macOS icon grid, 824 pt square with ~100 pt margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(body, 186)
withShadow(CGSize(width: 0, height: -14), 28, color(0x000000, 0.28)) {
    color(0xE9E2D3).setFill(); bodyPath.fill()
}
NSGradient(colors: [color(0xF5F0E6), color(0xE4DBCB)])!.draw(in: bodyPath, angle: -90)
// A thin highlight along the top edge, like light catching a moulded case.
NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
color(0xFFFFFF, 0.55).setStroke()
let rim = squircle(body.insetBy(dx: 3, dy: 3), 183); rim.lineWidth = 4; rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// Three fader slots with tick marks.
let centers: [CGFloat] = [332, 512, 692]
let slotBottom: CGFloat = 236, slotTop: CGFloat = 788
for x in centers {
    // tick marks on the left of each slot
    color(0xB8AD98).setFill()
    for i in 0...8 {
        let y = slotBottom + 20 + CGFloat(i) * (slotTop - slotBottom - 40) / 8
        let w: CGFloat = (i % 4 == 0) ? 34 : 22
        rounded(CGRect(x: x - 50 - w, y: y - 3, width: w, height: 6), 3).fill()
    }
    let slot = rounded(CGRect(x: x - 22, y: slotBottom, width: 44, height: slotTop - slotBottom), 22)
    color(0x2B2724).setFill(); slot.fill()
}

// Fader caps at different levels — one per app, one of them highlighted.
let levels: [CGFloat] = [560, 400, 655]
for (i, x) in centers.enumerated() {
    let cap = CGRect(x: x - 76, y: levels[i] - 44, width: 152, height: 88)
    let path = rounded(cap, 20)
    let accent = i == 1
    withShadow(CGSize(width: 0, height: -10), 16, color(0x000000, 0.35)) {
        (accent ? color(0xE2582A) : color(0xDCDCDC)).setFill(); path.fill()
    }
    NSGradient(colors: accent ? [color(0xF4773F), color(0xD9501F)] : [color(0xFFFFFF), color(0xD6D6D3)])!
        .draw(in: path, angle: -90)
    // grip line across the cap
    (accent ? color(0xFFFFFF, 0.75) : color(0x5B5650, 0.8)).setFill()
    rounded(CGRect(x: cap.minX + 22, y: cap.midY - 4, width: cap.width - 44, height: 8), 4).fill()
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
