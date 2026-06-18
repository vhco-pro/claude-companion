#!/usr/bin/env swift
// Generates a black-on-transparent menu-bar TEMPLATE from the color VH logo (white bg → clear,
// the colored mark → black with anti-aliased alpha). Run: swift scripts/make-menubar-template.swift
import AppKit
import CoreGraphics

let root = FileManager.default.currentDirectoryPath
let src = "\(root)/ClaudeCompanion/AppIcon.icon/Assets/Logo.png"
let outDir = "\(root)/ClaudeCompanion/Assets.xcassets/MenuBarIcon.imageset"

guard let nsImg = NSImage(contentsOfFile: src),
      let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot load \(src)\n".data(using: .utf8)!); exit(1)
}

let w = cg.width, h = cg.height
let bpr = w * 4
var pixels = [UInt8](repeating: 0, count: h * bpr)
let cs = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
guard let rctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: bpr, space: cs, bitmapInfo: info) else { exit(1) }
rctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// Build the template: black RGB, alpha = how-far-from-white (gated by source alpha).
var out = [UInt8](repeating: 0, count: h * bpr)
for i in stride(from: 0, to: pixels.count, by: 4) {
    let r = Double(pixels[i]), g = Double(pixels[i+1]), b = Double(pixels[i+2])
    let srcA = Double(pixels[i+3]) / 255.0
    let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0       // 0 (dark) … 1 (white)
    var a = (0.90 - lum) / 0.14                                  // white→<0, mark→~1, AA band
    a = max(0, min(1, a)) * srcA
    out[i] = 0; out[i+1] = 0; out[i+2] = 0; out[i+3] = UInt8(a * 255)
}
guard let octx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8,
                           bytesPerRow: bpr, space: cs, bitmapInfo: info),
      let templateFull = octx.makeImage() else { exit(1) }

func writePNG(_ image: CGImage, size: Int, to path: String) {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs, bitmapInfo: info) else { return }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: scaled)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(size)px)")
    }
}

// Menu-bar ~18pt: ship @1x (18), @2x (36), @3x (54).
writePNG(templateFull, size: 18, to: "\(outDir)/menubar-18.png")
writePNG(templateFull, size: 36, to: "\(outDir)/menubar-36.png")
writePNG(templateFull, size: 54, to: "\(outDir)/menubar-54.png")
