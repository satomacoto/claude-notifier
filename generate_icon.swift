import AppKit

// SVG-like icon drawn with Core Graphics
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded rect background with gradient
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect, cornerWidth: 220, cornerHeight: 220, transform: nil)
ctx.addPath(path)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.855, green: 0.467, blue: 0.337, alpha: 1.0), // #DA7756
    CGColor(red: 0.769, green: 0.380, blue: 0.243, alpha: 1.0)  // #C4613E
] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Bell body (flipped Y because CG origin is bottom-left)
let centerX = CGFloat(512)
let centerY = CGFloat(544) // flipped from SVG's 480

let bellPath = CGMutablePath()
bellPath.move(to: CGPoint(x: centerX, y: centerY + 240))
bellPath.addCurve(to: CGPoint(x: centerX - 200, y: centerY + 40),
                  control1: CGPoint(x: centerX - 132, y: centerY + 240),
                  control2: CGPoint(x: centerX - 200, y: centerY + 160))
bellPath.addCurve(to: CGPoint(x: centerX - 280, y: centerY - 220),
                  control1: CGPoint(x: centerX - 200, y: centerY - 80),
                  control2: CGPoint(x: centerX - 220, y: centerY - 160))
bellPath.addLine(to: CGPoint(x: centerX + 280, y: centerY - 220))
bellPath.addCurve(to: CGPoint(x: centerX + 200, y: centerY + 40),
                  control1: CGPoint(x: centerX + 220, y: centerY - 160),
                  control2: CGPoint(x: centerX + 200, y: centerY - 80))
bellPath.addCurve(to: CGPoint(x: centerX, y: centerY + 240),
                  control1: CGPoint(x: centerX + 200, y: centerY + 160),
                  control2: CGPoint(x: centerX + 132, y: centerY + 240))
bellPath.closeSubpath()

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.addPath(bellPath)
ctx.fillPath()

// Bell clapper
let clapperPath = CGMutablePath()
clapperPath.move(to: CGPoint(x: centerX - 70, y: centerY - 220))
clapperPath.addCurve(to: CGPoint(x: centerX, y: centerY - 300),
                     control1: CGPoint(x: centerX - 70, y: centerY - 260),
                     control2: CGPoint(x: centerX - 40, y: centerY - 300))
clapperPath.addCurve(to: CGPoint(x: centerX + 70, y: centerY - 220),
                     control1: CGPoint(x: centerX + 40, y: centerY - 300),
                     control2: CGPoint(x: centerX + 70, y: centerY - 260))

ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(48)
ctx.setLineCap(.round)
ctx.addPath(clapperPath)
ctx.strokePath()

image.unlockFocus()

// Save as PNG
let tiffData = image.tiffRepresentation!
let bitmapRep = NSBitmapImageRep(data: tiffData)!
let pngData = bitmapRep.representation(using: .png, properties: [:])!
try! pngData.write(to: URL(fileURLWithPath: "/Users/sato/src/github.com/satomacoto/claude-notifier/icon_1024.png"))
print("Saved icon_1024.png")
