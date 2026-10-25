import AppKit
import CoreGraphics

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.13, green: 0.34, blue: 0.28, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
for column in 0..<2 {
    for row in 0..<3 {
        let raised = column == 0 || row == 1
        context.setFillColor(raised ? CGColor(red: 0.83, green: 0.94, blue: 0.48, alpha: 1) : CGColor(red: 0.26, green: 0.45, blue: 0.38, alpha: 1))
        context.fillEllipse(in: CGRect(x: 305 + column * 250, y: 205 + row * 225, width: 160, height: 160))
    }
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Brailio/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
