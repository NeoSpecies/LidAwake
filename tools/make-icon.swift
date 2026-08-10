// 生成 App 图标：AppIcon.icns
// 用法: swift tools/make-icon.swift Resources
//
// 本机只有 CLT，没有设计工具，所以用 CoreGraphics 直接画：
// 深蓝渐变圆角方形（macOS 图标标准比例）+ 白色笔记本 + 琥珀色闪电角标。
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = outDir + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// 把 SF Symbol 渲染成指定尺寸、指定颜色的位图
func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(cfg) else { return nil }
    let tinted = NSImage(size: img.size)
    tinted.lockFocus()
    color.set()
    let rect = NSRect(origin: .zero, size: img.size)
    img.draw(in: rect)
    rect.fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func render(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS 图标规范：内容占画布约 80%，四周留白
    let inset = s * 0.10
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = NSBezierPath(roundedRect: body,
                               xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.34, blue: 0.85, alpha: 1),
                        NSColor(srgbRed: 0.09, green: 0.13, blue: 0.42, alpha: 1)])?
        .draw(in: squircle, angle: -90)

    // 顶部高光，让图标不至于死板
    squircle.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])?
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2),
              angle: -90)

    // 笔记本（略微上移，给右下角标腾位置）
    if let laptop = symbol("laptopcomputer", size: s * 0.38, color: .white) {
        let w = laptop.size.width, h = laptop.size.height
        laptop.draw(in: NSRect(x: (s - w) / 2 - s * 0.015, y: (s - h) / 2 + s * 0.055,
                               width: w, height: h))
    }

    // 闪电角标：表示"合盖后仍在通电运行"。
    // 垫一层深色圆底 + 浅色描边，否则闪电会和笔记本底座糊在一起。
    let badgeD = s * 0.30
    let badge = NSRect(x: s * 0.585, y: s * 0.150, width: badgeD, height: badgeD)
    NSColor(srgbRed: 0.06, green: 0.09, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: badge).fill()
    NSColor(white: 1, alpha: 0.28).setStroke()
    let ring = NSBezierPath(ovalIn: badge.insetBy(dx: s * 0.006, dy: s * 0.006))
    ring.lineWidth = s * 0.012
    ring.stroke()
    if let bolt = symbol("bolt.fill", size: badgeD * 0.56,
                         color: NSColor(srgbRed: 1.0, green: 0.78, blue: 0.20, alpha: 1)) {
        let w = bolt.size.width, h = bolt.size.height
        bolt.draw(in: NSRect(x: badge.midX - w / 2, y: badge.midY - h / 2, width: w, height: h))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// iconutil 要求的完整尺寸集
let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (px, name) in variants {
    guard let data = render(px).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("生成 \(name) 失败\n".utf8))
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

// 单独导出一张 1024 给 README 用
if let data = render(1024).representation(using: .png, properties: [:]) {
    try data.write(to: URL(fileURLWithPath: outDir + "/icon-1024.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", outDir + "/AppIcon.icns"]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 失败\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(atPath: iconset)
print("已生成 \(outDir)/AppIcon.icns 与 \(outDir)/icon-1024.png")
