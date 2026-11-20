// Рисует иконку приложения: слева шум (столбики случайной высоты), в центре граница, справа тишина.
// Использование: swift scripts/make-icon.swift <out.png> [размер=1024]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let size = args.count > 2 ? Int(args[2]) ?? 1024 : 1024
let s = CGFloat(size) / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Подложка по сетке иконок macOS: 824×824 в холсте 1024, скругление ~185.
let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
shadow.shadowBlurRadius = 22 * s
shadow.set()
rgb(0x1E3A8A).setFill()
platePath.fill()
ctx.restoreGState()
NSGradient(starting: rgb(0x3B5BDB), ending: rgb(0x0C8599))!.draw(in: platePath, angle: -90)

// Шум: столбики случайной (детерминированной) высоты, слева от границы.
var seed: UInt64 = 7
func rnd() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
let mid = 512 * s
let barW = 22 * s, gap = 14 * s
var x = 228 * s
let borderX = 640 * s
let count = Int(((borderX - 40 * s) - x) / (barW + gap))
for i in 0..<count {
    let t = CGFloat(i) / CGFloat(max(count - 1, 1))      // 0 у левого края, 1 у границы
    let h = (150 + rnd() * 330) * s * (1 - 0.25 * t)
    let r = NSRect(x: x, y: mid - h / 2, width: barW, height: h)
    NSColor.white.withAlphaComponent(0.55 + 0.4 * (1 - t)).setFill()
    NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    x += barW + gap
}

// Граница.
let border = NSRect(x: borderX, y: mid - 280 * s, width: 34 * s, height: 560 * s)
NSColor.white.setFill()
NSBezierPath(roundedRect: border, xRadius: 17 * s, yRadius: 17 * s).fill()

// Тишина: ровная тонкая линия справа.
let calm = NSRect(x: borderX + 74 * s, y: mid - 7 * s, width: 120 * s, height: 14 * s)
NSColor.white.withAlphaComponent(0.6).setFill()
NSBezierPath(roundedRect: calm, xRadius: 7 * s, yRadius: 7 * s).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
