import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: render_icon.swift <output-dir>\n", stderr)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let iconMap: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let tileRect = rect.insetBy(dx: size * 0.035, dy: size * 0.035)
    let tile = NSBezierPath(
        roundedRect: tileRect,
        xRadius: size * 0.19,
        yRadius: size * 0.19
    )

    NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.16, alpha: 1).setFill()
    tile.fill()

    let atmosphereGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.44, blue: 0.92, alpha: 0.9),
        NSColor(calibratedRed: 0.82, green: 0.30, blue: 0.95, alpha: 0.82)
    ])!
    atmosphereGradient.draw(in: tile, angle: -28)

    let lowerFade = NSBezierPath(roundedRect: tileRect, xRadius: size * 0.19, yRadius: size * 0.19)
    let lowerFadeGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.0, alpha: 0.0),
        NSColor(calibratedRed: 0.01, green: 0.03, blue: 0.09, alpha: 0.78),
        NSColor(calibratedRed: 0.0, green: 0.01, blue: 0.05, alpha: 0.94)
    ])!
    lowerFadeGradient.draw(in: lowerFade, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSColor.white.withAlphaComponent(0.045).setFill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.08, y: size * 0.16, width: size * 0.38, height: size * 0.56)).fill()
    NSBezierPath(ovalIn: NSRect(x: size * 0.72, y: size * 0.23, width: size * 0.15, height: size * 0.46)).fill()
    NSGraphicsContext.restoreGraphicsState()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()
    NSColor.black.withAlphaComponent(0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: size * 0.17, y: size * 0.20, width: size * 0.66, height: size * 0.42), xRadius: size * 0.08, yRadius: size * 0.08).fill()
    NSShadow().set()

    let antennaWidth = size * 0.024
    for (start, end) in [
        (NSPoint(x: size * 0.43, y: size * 0.72), NSPoint(x: size * 0.34, y: size * 0.88)),
        (NSPoint(x: size * 0.58, y: size * 0.72), NSPoint(x: size * 0.68, y: size * 0.88))
    ] {
        let antenna = NSBezierPath()
        antenna.move(to: start)
        antenna.line(to: end)
        antenna.lineWidth = antennaWidth
        antenna.lineCapStyle = .round
        NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.12, alpha: 1).setStroke()
        antenna.stroke()

        let antennaHighlight = NSBezierPath()
        antennaHighlight.move(to: NSPoint(x: start.x - antennaWidth * 0.15, y: start.y + antennaWidth * 0.4))
        antennaHighlight.line(to: NSPoint(x: end.x - antennaWidth * 0.15, y: end.y - antennaWidth * 0.5))
        antennaHighlight.lineWidth = antennaWidth * 0.22
        antennaHighlight.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.55).setStroke()
        antennaHighlight.stroke()
    }

    for (index, radius) in [0.165, 0.118, 0.072].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: size * 0.23, y: size * 0.73),
            radius: size * radius,
            startAngle: 108,
            endAngle: 182
        )
        arc.lineWidth = size * (0.022 - CGFloat(index) * 0.002)
        arc.lineCapStyle = .round
        NSColor(calibratedRed: 0.43, green: 0.89, blue: 1.0, alpha: 0.92).setStroke()
        arc.stroke()
    }

    let shellRect = NSRect(x: size * 0.14, y: size * 0.34, width: size * 0.64, height: size * 0.40)
    let shell = NSBezierPath(roundedRect: shellRect, xRadius: size * 0.11, yRadius: size * 0.11)
    let shellGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.12, alpha: 1),
        NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.24, alpha: 1)
    ])!
    shellGradient.draw(in: shell, angle: -90)

    let shellRim = NSBezierPath(roundedRect: shellRect.insetBy(dx: size * 0.006, dy: size * 0.006), xRadius: size * 0.10, yRadius: size * 0.10)
    NSColor(calibratedWhite: 0.88, alpha: 0.95).setStroke()
    shellRim.lineWidth = size * 0.008
    shellRim.stroke()

    let shellTopGloss = NSBezierPath()
    shellTopGloss.move(to: NSPoint(x: shellRect.minX + size * 0.03, y: shellRect.maxY - size * 0.06))
    shellTopGloss.curve(
        to: NSPoint(x: shellRect.maxX - size * 0.02, y: shellRect.maxY - size * 0.06),
        controlPoint1: NSPoint(x: shellRect.minX + size * 0.16, y: shellRect.maxY + size * 0.02),
        controlPoint2: NSPoint(x: shellRect.maxX - size * 0.14, y: shellRect.maxY + size * 0.005)
    )
    shellTopGloss.curve(
        to: NSPoint(x: shellRect.minX + size * 0.06, y: shellRect.maxY - size * 0.11),
        controlPoint1: NSPoint(x: shellRect.maxX - size * 0.15, y: shellRect.maxY - size * 0.09),
        controlPoint2: NSPoint(x: shellRect.minX + size * 0.20, y: shellRect.maxY - size * 0.13)
    )
    shellTopGloss.close()
    let glossGradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.82),
        NSColor.white.withAlphaComponent(0.10)
    ])!
    glossGradient.draw(in: shellTopGloss, angle: -90)

    let bezelRect = shellRect.insetBy(dx: size * 0.036, dy: size * 0.044)
    let bezel = NSBezierPath(roundedRect: bezelRect, xRadius: size * 0.08, yRadius: size * 0.08)
    NSColor(calibratedRed: 0.01, green: 0.06, blue: 0.10, alpha: 1).setFill()
    bezel.fill()

    let innerScreenRect = bezelRect.insetBy(dx: size * 0.028, dy: size * 0.028)
    let innerScreen = NSBezierPath(roundedRect: innerScreenRect, xRadius: size * 0.055, yRadius: size * 0.055)

    let stripeColors: [NSColor] = [
        NSColor(calibratedRed: 0.16, green: 0.98, blue: 0.05, alpha: 1),
        NSColor(calibratedRed: 0.56, green: 0.98, blue: 0.10, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.90, blue: 0.93, alpha: 1),
        NSColor(calibratedRed: 0.14, green: 0.58, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.30, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.55, green: 0.24, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.88, green: 0.36, blue: 0.95, alpha: 1)
    ]
    let stripeWidth = innerScreenRect.width / CGFloat(stripeColors.count)
    NSGraphicsContext.saveGraphicsState()
    innerScreen.addClip()
    for (index, color) in stripeColors.enumerated() {
        let stripeRect = NSRect(
            x: innerScreenRect.minX + CGFloat(index) * stripeWidth,
            y: innerScreenRect.minY,
            width: stripeWidth + 1,
            height: innerScreenRect.height
        )
        color.setFill()
        NSBezierPath(rect: stripeRect).fill()
    }

    let diagonalShade = NSBezierPath()
    diagonalShade.move(to: NSPoint(x: innerScreenRect.minX, y: innerScreenRect.maxY))
    diagonalShade.line(to: NSPoint(x: innerScreenRect.maxX, y: innerScreenRect.maxY))
    diagonalShade.line(to: NSPoint(x: innerScreenRect.maxX, y: innerScreenRect.minY + innerScreenRect.height * 0.35))
    diagonalShade.close()
    NSColor.white.withAlphaComponent(0.18).setFill()
    diagonalShade.fill()

    let lowerShade = NSBezierPath()
    lowerShade.move(to: NSPoint(x: innerScreenRect.minX, y: innerScreenRect.minY))
    lowerShade.line(to: NSPoint(x: innerScreenRect.maxX, y: innerScreenRect.minY))
    lowerShade.line(to: NSPoint(x: innerScreenRect.maxX, y: innerScreenRect.minY + innerScreenRect.height * 0.55))
    lowerShade.close()
    NSColor.black.withAlphaComponent(0.22).setFill()
    lowerShade.fill()
    NSGraphicsContext.restoreGraphicsState()

    let playShadow = NSShadow()
    playShadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    playShadow.shadowBlurRadius = size * 0.018
    playShadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    playShadow.set()

    let playPath = NSBezierPath()
    let playRect = NSRect(x: size * 0.404, y: size * 0.46, width: size * 0.17, height: size * 0.18)
    playPath.move(to: NSPoint(x: playRect.minX, y: playRect.minY))
    playPath.line(to: NSPoint(x: playRect.maxX, y: playRect.midY))
    playPath.line(to: NSPoint(x: playRect.minX, y: playRect.maxY))
    playPath.close()
    let playGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.98),
        NSColor(calibratedWhite: 0.88, alpha: 0.96)
    ])!
    playGradient.draw(in: playPath, angle: -90)
    NSShadow().set()

    NSColor.white.withAlphaComponent(0.42).setStroke()
    innerScreen.lineWidth = size * 0.004
    innerScreen.stroke()

    let sidePanelRect = NSRect(x: shellRect.maxX - size * 0.078, y: shellRect.minY + size * 0.05, width: size * 0.075, height: shellRect.height - size * 0.10)
    let sidePanel = NSBezierPath(roundedRect: sidePanelRect, xRadius: size * 0.03, yRadius: size * 0.03)
    let sideGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.01, green: 0.03, blue: 0.10, alpha: 1)
    ])!
    sideGradient.draw(in: sidePanel, angle: -90)

    for (index, diameter) in [size * 0.045, size * 0.032].enumerated() {
        let knobRect = NSRect(
            x: sidePanelRect.midX - diameter / 2,
            y: sidePanelRect.midY + size * (index == 0 ? 0.03 : -0.03) - diameter / 2,
            width: diameter,
            height: diameter
        )
        let knob = NSBezierPath(ovalIn: knobRect)
        let knobGradient = NSGradient(colors: [
            NSColor.white,
            NSColor(calibratedWhite: 0.72, alpha: 1)
        ])!
        knobGradient.draw(in: knob, angle: -90)
        NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.98, alpha: 0.85).setStroke()
        knob.lineWidth = size * 0.003
        knob.stroke()
    }

    let glow = NSBezierPath(roundedRect: NSRect(x: size * 0.14, y: size * 0.33, width: size * 0.66, height: size * 0.42), xRadius: size * 0.11, yRadius: size * 0.11)
    NSColor(calibratedRed: 0.18, green: 0.84, blue: 1.0, alpha: 0.18).setStroke()
    glow.lineWidth = size * 0.01
    glow.stroke()

    let lanParagraph = NSMutableParagraphStyle()
    lanParagraph.alignment = .center

    let baselineY = size * 0.145
    let brandRect = NSRect(x: size * 0.12, y: baselineY, width: size * 0.76, height: size * 0.16)

    let lanText = NSAttributedString(
        string: "lan",
        attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.15, weight: .heavy),
            .foregroundColor: NSColor(calibratedRed: 0.11, green: 0.77, blue: 1.0, alpha: 1),
            .paragraphStyle: lanParagraph,
            .kern: -3.0
        ]
    )
    let tvText = NSAttributedString(
        string: "TV",
        attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.16, weight: .black),
            .foregroundColor: NSColor.white,
            .paragraphStyle: lanParagraph,
            .kern: -4.0
        ]
    )

    let brandLine = NSMutableAttributedString()
    brandLine.append(lanText)
    brandLine.append(tvText)
    brandLine.draw(in: brandRect)

    let topHighlight = NSBezierPath(roundedRect: tileRect.insetBy(dx: size * 0.008, dy: size * 0.008), xRadius: size * 0.18, yRadius: size * 0.18)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    topHighlight.lineWidth = size * 0.003
    topHighlight.stroke()

    image.unlockFocus()
    return image
}

for (pixelSize, fileName) in iconMap {
    let image = drawIcon(size: CGFloat(pixelSize))
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("failed to encode \(fileName)\n", stderr)
        exit(1)
    }

    try png.write(to: outputDirectory.appendingPathComponent(fileName))
}
