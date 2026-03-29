import AppKit

// Generate AppIcon.icns for claude-notifier
// Design: Claude starburst inside a speech bubble on a Claude Code terracotta background
// Matches the menu bar icon design but with color

// Claude symbol SVG path (from Wikipedia, viewBox 0 0 1200 1200)
let claudePath = "M 233.959793 800.214905 L 468.644287 668.536987 L 472.590637 657.100647 L 468.644287 650.738403 L 457.208069 650.738403 L 417.986633 648.322144 L 283.892639 644.69812 L 167.597321 639.865845 L 54.926208 633.825623 L 26.577238 627.785339 L 3.3e-05 592.751709 L 2.73832 575.27533 L 26.577238 559.248352 L 60.724873 562.228149 L 136.187973 567.382629 L 249.422867 575.194763 L 331.570496 580.026978 L 453.261841 592.671082 L 472.590637 592.671082 L 475.328857 584.859009 L 468.724915 580.026978 L 463.570557 575.194763 L 346.389313 495.785217 L 219.543671 411.865906 L 153.100723 363.543762 L 117.181267 339.060425 L 99.060455 316.107361 L 91.248367 266.01355 L 123.865784 230.093994 L 167.677887 233.073853 L 178.872513 236.053772 L 223.248367 270.201477 L 318.040283 343.570496 L 441.825592 434.738342 L 459.946411 449.798706 L 467.194672 444.64447 L 468.080597 441.020203 L 459.946411 427.409485 L 392.617493 305.718323 L 320.778564 181.932983 L 288.80542 130.630859 L 280.348999 99.865845 C 277.369171 87.221436 275.194641 76.590698 275.194641 63.624268 L 312.322174 13.20813 L 332.8591 6.604126 L 382.389313 13.20813 L 403.248352 31.328979 L 434.013519 101.71814 L 483.865753 212.537048 L 561.181274 363.221497 L 583.812134 407.919434 L 595.892639 449.315491 L 600.40271 461.959839 L 608.214783 461.959839 L 608.214783 454.711609 L 614.577271 369.825623 L 626.335632 265.61084 L 637.771851 131.516846 L 641.718201 93.745117 L 660.402832 48.483276 L 697.530334 24.000122 L 726.52356 37.852417 L 750.362549 72 L 747.060486 94.067139 L 732.886047 186.201416 L 705.100708 330.52356 L 686.979919 427.167847 L 697.530334 427.167847 L 709.61084 415.087341 L 758.496704 350.174561 L 840.644348 247.490051 L 876.885925 206.738342 L 919.167847 161.71814 L 946.308838 140.29541 L 997.61084 140.29541 L 1035.38269 196.429626 L 1018.469849 254.416199 L 965.637634 321.422852 L 921.825562 378.201538 L 859.006714 462.765259 L 819.785278 530.41626 L 823.409424 535.812073 L 832.75177 534.92627 L 974.657776 504.724915 L 1051.328979 490.872559 L 1142.818848 475.167786 L 1184.214844 494.496582 L 1188.724854 514.147644 L 1172.456421 554.335693 L 1074.604126 578.496765 L 959.838989 601.449829 L 788.939636 641.879272 L 786.845764 643.409485 L 789.261841 646.389343 L 866.255127 653.637634 L 899.194702 655.409424 L 979.812134 655.409424 L 1129.932861 666.604187 L 1169.154419 692.537109 L 1192.671265 724.268677 L 1188.724854 748.429688 L 1128.322144 779.194641 L 1046.818848 759.865845 L 856.590759 714.604126 L 791.355774 698.335754 L 782.335693 698.335754 L 782.335693 703.731567 L 836.69812 756.885986 L 936.322205 846.845581 L 1061.073975 962.81897 L 1067.436279 991.490112 L 1051.409424 1014.120911 L 1034.496704 1011.704712 L 924.885986 929.234924 L 882.604126 892.107544 L 786.845764 811.48999 L 780.483276 811.48999 L 780.483276 819.946289 L 802.550415 852.241699 L 919.087341 1027.409424 L 925.127625 1081.127686 L 916.671204 1098.604126 L 886.469849 1109.154419 L 853.288696 1103.114136 L 785.073914 1007.355835 L 714.684631 899.516785 L 657.906067 802.872498 L 650.979858 806.81897 L 617.476624 1167.704834 L 601.771851 1186.147705 L 565.530212 1200 L 535.328857 1177.046997 L 519.302124 1139.919556 L 535.328857 1066.550537 L 554.657776 970.792053 L 570.362488 894.68457 L 584.536926 800.134277 L 592.993347 768.724976 L 592.429626 766.630859 L 585.503479 767.516968 L 514.22821 865.369263 L 405.825531 1011.865906 L 320.053711 1103.677979 L 299.516815 1111.812256 L 263.919525 1093.369263 L 267.221497 1060.429688 L 287.114136 1031.114136 L 405.825531 880.107361 L 477.422913 786.52356 L 523.651062 732.483276 L 523.328918 724.671265 L 520.590698 724.671265 L 205.288605 929.395935 L 149.154434 936.644409 L 124.993355 914.01355 L 127.973183 876.885986 L 139.409409 864.80542 L 234.201385 799.570435 L 233.879227 799.8927 Z"

func parseSVGPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    let scanner = Scanner(string: d)
    scanner.charactersToBeSkipped = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))
    var currentX: CGFloat = 0, currentY: CGFloat = 0
    var lastCommand: Character = "M"
    while !scanner.isAtEnd {
        var cmd: NSString?
        if scanner.scanCharacters(from: CharacterSet.letters, into: &cmd), let c = cmd as String? {
            lastCommand = Character(c)
        }
        switch lastCommand {
        case "M":
            if let x = scanner.scanDouble(), let y = scanner.scanDouble() {
                currentX = CGFloat(x); currentY = CGFloat(y)
                path.move(to: CGPoint(x: currentX, y: currentY))
                lastCommand = "L"
            }
        case "L":
            if let x = scanner.scanDouble(), let y = scanner.scanDouble() {
                currentX = CGFloat(x); currentY = CGFloat(y)
                path.addLine(to: CGPoint(x: currentX, y: currentY))
            }
        case "C":
            if let x1 = scanner.scanDouble(), let y1 = scanner.scanDouble(),
               let x2 = scanner.scanDouble(), let y2 = scanner.scanDouble(),
               let x = scanner.scanDouble(), let y = scanner.scanDouble() {
                currentX = CGFloat(x); currentY = CGFloat(y)
                path.addCurve(to: CGPoint(x: currentX, y: currentY),
                             control1: CGPoint(x: CGFloat(x1), y: CGFloat(y1)),
                             control2: CGPoint(x: CGFloat(x2), y: CGFloat(y2)))
            }
        case "Z":
            path.closeSubpath()
        default:
            break
        }
    }
    return path
}

// Claude Code colors
let claudeOrange = CGColor(srgbRed: 0.839, green: 0.459, blue: 0.306, alpha: 1.0) // #D6754E terracotta
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let scriptDir = "/Users/sato/src/github.com/satomacoto/claude-notifier"
let iconsetPath = "\(scriptDir)/AppIcon.iconset"

// Create iconset directory
try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for baseSize in sizes {
    for scale in [1, 2] {
        let pixelSize = baseSize * scale
        if pixelSize > 1024 { continue }

        let s = CGFloat(pixelSize)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        // Keep the drawing coordinate space aligned to the bitmap pixel size.
        // Using the base size here causes @2x variants to render only a quadrant.
        rep.size = NSSize(width: s, height: s)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext

        cg.setShouldAntialias(true)
        cg.setAllowsAntialiasing(true)

        // -- Background: rounded rect (macOS icon shape) --
        let cornerRadius = s * 0.22
        let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        cg.setFillColor(claudeOrange)
        cg.addPath(bgPath)
        cg.fillPath()

        // -- Speech bubble (filled white) --
        let bubbleCX = s * 0.50
        let bubbleCY_td = s * 0.42         // center Y (top-down)
        let bubbleW = s * 0.72
        let bubbleH = s * 0.54
        let cr = s * 0.10

        let bubbleLeft = bubbleCX - bubbleW / 2
        let bubbleBottomY_td = bubbleCY_td + bubbleH / 2
        // CG coords
        let bubbleRect = CGRect(x: bubbleLeft, y: s - bubbleBottomY_td, width: bubbleW, height: bubbleH)
        let outerBubble = CGPath(roundedRect: bubbleRect, cornerWidth: cr, cornerHeight: cr, transform: nil)

        // Tail triangle
        let tailPath = CGMutablePath()
        let tailAnchorX = bubbleLeft + bubbleW * 0.25
        let tailBottomCG = s - bubbleBottomY_td
        let tailTipCG = tailBottomCG - s * 0.16
        let tailHalfW = s * 0.10
        tailPath.move(to: CGPoint(x: tailAnchorX - tailHalfW, y: tailBottomCG + s * 0.01))
        tailPath.addLine(to: CGPoint(x: tailAnchorX - tailHalfW * 1.5, y: tailTipCG))
        tailPath.addLine(to: CGPoint(x: tailAnchorX + tailHalfW, y: tailBottomCG + s * 0.01))
        tailPath.closeSubpath()

        // Draw solid white bubble + tail
        cg.setFillColor(white)
        cg.addPath(outerBubble)
        cg.fillPath()
        cg.addPath(tailPath)
        cg.fillPath()

        // -- Claude starburst (terracotta) inside bubble --
        let svgSize: CGFloat = 1200
        let pad = s * 0.04
        let targetRect = bubbleRect.insetBy(dx: pad, dy: pad)
        let fitScale = min(targetRect.width, targetRect.height) / svgSize

        cg.saveGState()
        cg.addPath(outerBubble)
        cg.clip()

        // Center starburst in bubble: translate to center, scale+flip, offset SVG origin
        cg.translateBy(x: bubbleRect.midX, y: bubbleRect.midY)
        cg.scaleBy(x: fitScale, y: -fitScale)
        cg.translateBy(x: -svgSize / 2, y: -svgSize / 2)

        let symbolPath = parseSVGPath(claudePath)
        cg.addPath(symbolPath)
        cg.setFillColor(claudeOrange)
        cg.fillPath()
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        let pngData = rep.representation(using: .png, properties: [:])!
        let suffix = scale == 1 ? "" : "@2x"
        let filename = "icon_\(baseSize)x\(baseSize)\(suffix).png"
        let path = "\(iconsetPath)/\(filename)"
        try! pngData.write(to: URL(fileURLWithPath: path))
        print("Saved \(filename) (\(pixelSize)x\(pixelSize))")

    }
}

// Convert iconset to icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", "\(scriptDir)/AppIcon.icns"]
try! process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Generated AppIcon.icns")
    // Keep iconset for debugging
    // try? FileManager.default.removeItem(atPath: iconsetPath)
} else {
    print("Error: iconutil failed with status \(process.terminationStatus)")
}
