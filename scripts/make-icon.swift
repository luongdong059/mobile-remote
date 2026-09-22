// Composes a 1024 px macOS app icon: the logo on a rounded-rect body that
// follows Apple's icon grid (824 px body, transparent margin, soft shadow).
// usage: swift scripts/make-icon.swift logo.png icon-1024.png
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let logo = NSImage(contentsOfFile: arguments[1]),
      let logoImage = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift logo.png icon-1024.png\n".utf8))
    exit(1)
}

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.3))
context.addPath(shape)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(shape)
context.clip()
let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
              CGColor(red: 0.82, green: 0.91, blue: 0.99, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
context.restoreGState()

context.interpolationQuality = .high
let logoSide: CGFloat = 600
context.draw(logoImage, in: CGRect(x: (CGFloat(size) - logoSide) / 2, y: (CGFloat(size) - logoSide) / 2,
                                   width: logoSide, height: logoSide))

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
