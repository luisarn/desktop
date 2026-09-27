import AppKit
import ImageIO

// 生成 Mode 用的 320x160 黑底 OLED GIF：品牌图（居中）+ 可选白色等宽字标签。
// 用法:
//   swift generate_agent_gif.swift <input-image> <output.gif> [--label "Kimi Code"]

func argValue(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

guard CommandLine.arguments.count >= 3 else {
    print("usage: generate_agent_gif.swift <input> <output.gif> [--label text]")
    exit(1)
}
let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]
let label = argValue("--label")

guard let source = NSImage(contentsOfFile: inputPath) else {
    print("cannot read input image: \(inputPath)")
    exit(1)
}

let canvasW = 320, canvasH = 160
let canvas = NSImage(size: NSSize(width: canvasW, height: canvasH))
canvas.lockFocus()
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: canvasW, height: canvasH).fill()

let hasLabel = label != nil && !label!.isEmpty
let labelBand: CGFloat = hasLabel ? 48 : 0
let imageBoxMaxW: CGFloat = 290
let imageBoxMaxH: CGFloat = hasLabel ? 100 : 146
let srcW = source.size.width, srcH = source.size.height
let scale = min(imageBoxMaxW / srcW, imageBoxMaxH / srcH, 1.0)
let imgW = srcW * scale, imgH = srcH * scale
let imgX = (CGFloat(canvasW) - imgW) / 2
let bandMinY = labelBand
let bandHeight = CGFloat(canvasH) - labelBand - 6
let imgY = bandMinY + (bandHeight - imgH) / 2

NSGraphicsContext.current?.imageInterpolation = .high
source.draw(in: NSRect(x: imgX, y: imgY, width: imgW, height: imgH),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0)

if hasLabel, let label {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Menlo-Bold", size: 28) ?? NSFont.boldSystemFont(ofSize: 28),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
    ]
    let size = (label as NSString).size(withAttributes: attrs)
    (label as NSString).draw(at: NSPoint(x: (CGFloat(canvasW) - size.width) / 2, y: 10), withAttributes: attrs)
}
canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let gifData = bitmap.representation(using: .gif, properties: [:]) else {
    print("failed to encode gif")
    exit(1)
}
try gifData.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(gifData.count) bytes)")
