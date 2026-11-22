#!/usr/bin/env swift
// Renders the Model Switch app icon (vector, deterministic) at every size the
// macOS iconset format needs.
//
//   swift tools/make-icon.swift build/AppIcon.iconset
//   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
//
// The design: graphite-blue squircle (superellipse, continuous-corner feel),
// a toggle switch in the middle — three dots (the models) on the left side of
// the track, an orange knob carrying a four-point sparkle (the active pick).
import AppKit

let canvas: CGFloat = 1024

func squircle(center c: NSPoint, size s: NSSize, exponent n: CGFloat = 5.0, steps: Int = 240) -> NSBezierPath {
    let a = s.width / 2, b = s.height / 2
    let p = NSBezierPath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1: 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1: 1) * pow(abs(st), 2 / n)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

/// Four-point concave star (astroid): x = r·cos³t, y = r·sin³t.
func star4(center c: NSPoint, radius r: CGFloat, steps: Int = 144) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let k = cos(t), m = sin(t)
        let x = c.x + r * k * k * k
        let y = c.y + r * m * m * m
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// Draws the whole icon in 1024x1024 space (origin bottom-left).
/// currentPx = the pixel size currently being rendered (AppKit has no other way to know).
var currentPx: CGFloat = canvas
func drawIcon() {
    let center = NSPoint(x: 512, y: 512)

    // --- background squircle -------------------------------------------------
    let bg = squircle(center: center, size: NSSize(width: 824, height: 824), exponent: 5)
    NSGradient(starting: rgb(0x1B, 0x1C, 0x2B), ending: rgb(0x4A, 0x4E, 0x6E))!
        .draw(in: bg, angle: 90)
    bg.lineWidth = 3
    bg.lineJoinStyle = .round // sampled superellipse kinks spike with miter joins
    // Below this the 3pt hairline rasterizes as beads on the polygon's
    // highest-curvature samples — skip it and let the fill read on its own.
    if currentPx >= 128 {
        NSColor(white: 1, alpha: 0.10).setStroke()
        bg.stroke()
    }

    // Soft top gloss, clipped to the squircle.
    bg.addClip()
    let gloss = NSBezierPath(roundedRect: NSRect(x: 60, y: 512, width: 904, height: 620),
                             xRadius: 300, yRadius: 300)
    NSGradient(starting: NSColor(white: 1, alpha: 0.0), ending: NSColor(white: 1, alpha: 0.07))?
        .draw(in: gloss, angle: 90)
    NSGraphicsContext.current?.cgContext.resetClip()

    // --- toggle track ----------------------------------------------------------
    let trackW: CGFloat = 470, trackH: CGFloat = 204
    let trackRect = NSRect(x: 512 - trackW / 2, y: 512 - trackH / 2, width: trackW, height: trackH)
    let track = NSBezierPath(roundedRect: trackRect, xRadius: trackH / 2, yRadius: trackH / 2)
    rgb(0, 0, 0, 0.38).setFill()
    track.fill()
    track.lineWidth = 3
    NSColor(white: 1, alpha: 0.12).setStroke()
    track.stroke()

    // --- model dots (left side of the track) -----------------------------------
    let dotR: CGFloat = 22
    for i in 0..<3 {
        let dot = NSBezierPath(ovalIn: NSRect(x: 340 + CGFloat(i) * 90 - dotR,
                                              y: 512 - dotR, width: dotR * 2, height: dotR * 2))
        NSColor(white: 1, alpha: 0.50).setFill()
        dot.fill()
    }

    // --- knob (right side, "on") -------------------------------------------------
    let knobC = NSPoint(x: 647, y: 512), knobR: CGFloat = 84

    // Warm glow spilling onto the track behind the knob.
    NSGradient(starting: rgb(255, 150, 70, 0.45), ending: rgb(255, 150, 70, 0))?
        .draw(fromCenter: knobC, radius: knobR,
              toCenter: knobC, radius: knobR + 150, options: [])

    let knob = NSBezierPath(ovalIn: NSRect(x: knobC.x - knobR, y: knobC.y - knobR,
                                           width: knobR * 2, height: knobR * 2))
    NSGradient(starting: rgb(0xF5, 0x68, 0x28), ending: rgb(0xFF, 0xC2, 0x4D))?
        .draw(in: knob, angle: 90)

    // Sheen highlight, upper-left of the knob.
    NSGraphicsContext.current?.cgContext.saveGState()
    knob.addClip()
    NSGradient(starting: NSColor(white: 1, alpha: 0.40), ending: NSColor(white: 1, alpha: 0))?
        .draw(fromCenter: NSPoint(x: knobC.x - 24, y: knobC.y + 30), radius: 8,
              toCenter: NSPoint(x: knobC.x - 24, y: knobC.y + 30), radius: 96, options: [])
    NSGraphicsContext.current?.cgContext.restoreGState()

    // Sparkle: the "model" the switch picked.
    let sparkle = star4(center: knobC, radius: 40)
    NSColor(white: 1, alpha: 0.96).setFill()
    sparkle.fill()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    currentPx = CGFloat(px)
    ctx.cgContext.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - main

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let names = ["icon_16x16.png", "icon_16x16@2x.png",
             "icon_32x32.png", "icon_32x32@2x.png",
             "icon_128x128.png", "icon_128x128@2x.png",
             "icon_256x256.png", "icon_256x256@2x.png",
             "icon_512x512.png", "icon_512x512@2x.png"]
let sizes = [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024]

for (name, px) in zip(names, sizes) {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// A 1024 master PNG next to the iconset for quick visual checks.
try! render(1024).write(to: URL(fileURLWithPath: "\(outDir)/icon_512x512@2x.png"))
print("wrote \(names.count) PNGs to \(outDir)")
