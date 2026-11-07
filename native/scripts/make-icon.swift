// Draws Moodboard's icon: the wall's staggered columns on its dark ground. Run with `swift scripts/make-icon.swift`.
import AppKit

func picture(size: Int) -> Data {
  let scale = CGFloat(size) / 1024
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let plate = NSBezierPath(roundedRect: NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale), xRadius: 185 * scale, yRadius: 185 * scale)
  NSColor(srgbRed: 0.075, green: 0.078, blue: 0.082, alpha: 1).setFill()
  plate.fill()
  plate.addClip()

  let paper = NSColor(srgbRed: 0.957, green: 0.949, blue: 0.918, alpha: 1)
  let leaf = NSColor(srgbRed: 0.153, green: 0.275, blue: 0.204, alpha: 1)
  let apricot = NSColor(srgbRed: 0.867, green: 0.478, blue: 0.184, alpha: 1)
  let columns: [(x: CGFloat, cards: [(y: CGFloat, h: CGFloat, color: NSColor)])] = [
    (150, [(-60, 240, paper), (205, 330, leaf), (560, 240, paper), (825, 240, paper)]),
    (400, [(40, 300, apricot), (365, 200, paper), (590, 360, paper)]),
    (650, [(-20, 180, paper), (185, 380, paper), (590, 250, leaf), (865, 200, paper)]),
  ]
  for column in columns {
    for card in column.cards {
      card.color.setFill()
      NSBezierPath(roundedRect: NSRect(x: column.x * scale, y: card.y * scale, width: 224 * scale, height: card.h * scale), xRadius: 26 * scale, yRadius: 26 * scale).fill()
    }
  }
  NSGraphicsContext.current = nil
  return rep.representation(using: .png, properties: [:])!
}

let set = URL(filePath: NSTemporaryDirectory()).appending(path: "Moodboard.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  try picture(size: size).write(to: set.appending(path: "icon_\(size)x\(size).png"))
  try picture(size: size * 2).write(to: set.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(filePath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", set.path, "-o", "Moodboard/Resources/AppIcon.icns"]
try tool.run()
tool.waitUntilExit()
