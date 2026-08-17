import AppKit
import ImageIO
import CoreGraphics
import Foundation

// Winder 앱 아이콘 생성기 — 1024 기준으로 그리고 각 크기로 렌더링한다.
// 디자인: macOS 스타일 둥근 사각형(Fluent 파랑 그라디언트) + 흰 폴더 + Windows 11 창 모티프

func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

/// 모서리가 둥근 사각형 경로
func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size / 1024
    guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)

    // MARK: 배경 — macOS 아이콘 그리드(1024 캔버스에 824 사각형)
    // macOS 26은 아이콘에 자체 모양·재질을 입히므로 배경은 캔버스를 꽉 채운다
    let plate = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let platePath = CGPath(rect: plate, transform: nil)
    context.addPath(platePath)
    context.setFillColor(hex(0x0078D4))
    context.fillPath()

    // 파랑 그라디언트 (위가 밝고 아래가 진하게)
    context.saveGState()
    context.addPath(platePath)
    context.clip()
    let colors = [hex(0x2B93E9), hex(0x0067BA), hex(0x004E8C)] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 512, y: 1024),
                                   end: CGPoint(x: 512, y: 0),
                                   options: [])
    }
    // 상단 광 — 경계가 보이지 않도록 부드럽게 퍼뜨린다
    if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                             colors: [hex(0xFFFFFF, alpha: 0.30), hex(0xFFFFFF, alpha: 0)] as CFArray,
                             locations: [0, 1]) {
        context.drawRadialGradient(glow,
                                   startCenter: CGPoint(x: 512, y: 1000), startRadius: 0,
                                   endCenter: CGPoint(x: 512, y: 1000), endRadius: 620,
                                   options: [])
    }
    context.restoreGState()

    // 폴더 전체를 아이콘 중심 기준으로 조금 키운다
    context.saveGState()
    context.translateBy(x: 512, y: 470)
    context.scaleBy(x: 1.12, y: 1.12)
    context.translateBy(x: -512, y: -470)

    // MARK: 폴더 뒤판(탭 포함)
    let backPath = CGMutablePath()
    let back = CGRect(x: 232, y: 348, width: 560, height: 330)
    backPath.addPath(roundedPath(back, 34))
    // 왼쪽 위 탭
    backPath.addPath(roundedPath(CGRect(x: 232, y: 596, width: 250, height: 130), 34))
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10),
                      blur: 26, color: hex(0x00243F, alpha: 0.45))
    context.addPath(backPath)
    context.setFillColor(hex(0xBBD9F5))
    context.fillPath()
    context.restoreGState()

    // MARK: 폴더 앞판
    let front = CGRect(x: 232, y: 300, width: 560, height: 300)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8),
                      blur: 20, color: hex(0x00243F, alpha: 0.35))
    context.addPath(roundedPath(front, 36))
    context.setFillColor(hex(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    // MARK: Windows 11 창 모티프 — 앞판 위 2×2 창살
    let paneWidth: CGFloat = 140
    let paneHeight: CGFloat = 96
    let gap: CGFloat = 26
    let gridWidth = paneWidth * 2 + gap
    let gridHeight = paneHeight * 2 + gap
    let originX = front.midX - gridWidth / 2
    let originY = front.midY - gridHeight / 2
    for row in 0..<2 {
        for column in 0..<2 {
            let pane = CGRect(x: originX + CGFloat(column) * (paneWidth + gap),
                              y: originY + CGFloat(row) * (paneHeight + gap),
                              width: paneWidth, height: paneHeight)
            // 위쪽 두 칸을 조금 더 진하게 — 창에 빛이 드는 느낌
            context.setFillColor(row == 1 ? hex(0x0F86DE) : hex(0x0A6CB8))
            context.addPath(roundedPath(pane, 16))
            context.fillPath()
        }
    }
    context.restoreGState()

    return context.makeImage()
}

// MARK: 파일 출력

let outputDirectory = CommandLine.arguments[1]
let sizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    guard let image = drawIcon(size: size) else { continue }
    let url = URL(fileURLWithPath: outputDirectory)
        .appendingPathComponent("icon_\(Int(size)).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(url.lastPathComponent)")
}

// 사용법:
//   swift Tools/MakeAppIcon.swift <출력폴더>
//   cp <출력폴더>/icon_*.png winder/Assets.xcassets/AppIcon.appiconset/
