import AppKit
import CoreImage

// 生成 1024x1024 应用图标：蓝色渐变圆角底 + 白色服务器符号
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let pixels = 1024

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.setShouldAntialias(true)

let size = CGFloat(pixels)
let padding: CGFloat = 46
let bodyRect = NSRect(x: padding, y: padding, width: size - padding * 2, height: size - padding * 2)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 196, yRadius: 196)

// 背景渐变
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.22, green: 0.50, blue: 0.92, alpha: 1.0),
    NSColor(srgbRed: 0.07, green: 0.23, blue: 0.52, alpha: 1.0)
])!
gradient.draw(in: bodyPath, angle: -78)

// 顶部柔光
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.16),
    NSColor.white.withAlphaComponent(0.0)
])!
let highlightRect = NSRect(x: bodyRect.minX, y: bodyRect.midY, width: bodyRect.width, height: bodyRect.height / 2)
let clipPath = NSBezierPath(roundedRect: bodyRect, xRadius: 196, yRadius: 196)
clipPath.addClip()
highlight.draw(in: highlightRect, angle: -90)
NSGraphicsContext.current!.cgContext.resetClip()

// 细描边
bodyPath.lineWidth = 4
NSColor.white.withAlphaComponent(0.20).setStroke()
bodyPath.stroke()

// 白色符号
func whiteGlyph(named: String, pointSize: CGFloat) -> NSImage? {
    guard let symbol = NSImage(systemSymbolName: named, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard let configured = symbol.withSymbolConfiguration(config) else { return nil }
    var rect = NSRect(x: 0, y: 0, width: configured.size.width, height: configured.size.height)
    guard let cgImage = configured.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    let input = CIImage(cgImage: cgImage)
    let filter = CIFilter(name: "CIColorMonochrome")!
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(CIColor.white, forKey: "inputColor")
    filter.setValue(1.0, forKey: kCIInputIntensityKey)
    guard let output = filter.outputImage else { return nil }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

if let glyph = whiteGlyph(named: "server.rack", pointSize: 420) {
    let maxWidth: CGFloat = size * 0.56
    let aspect = glyph.size.height / glyph.size.width
    let width = maxWidth
    let height = width * aspect
    let origin = NSRect(
        x: (size - width) / 2,
        y: (size - height) / 2 + size * 0.02,
        width: width,
        height: height
    )
    glyph.draw(in: origin, from: .zero, operation: .sourceOver, fraction: 0.95)
}

// 底部小圆点装饰：表示“已连接”
let dotRadius: CGFloat = 26
let dotRect = NSRect(x: size / 2 - dotRadius, y: size * 0.155, width: dotRadius * 2, height: dotRadius * 2)
let dotPath = NSBezierPath(ovalIn: dotRect)
NSColor(srgbRed: 0.42, green: 0.92, blue: 0.70, alpha: 0.92).setFill()
dotPath.fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    print("PNG 编码失败")
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成 \(outputPath)")
