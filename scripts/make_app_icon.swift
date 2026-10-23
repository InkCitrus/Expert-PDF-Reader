// Renders the OpenPDFExpert app icon — an original design, not PDF Expert's artwork:
// a dog-eared page whose surface shifts diagonally through the three reading themes
// (Day white → Sepia cream → Night charcoal), with the text lines changing ink color across
// the bands, on a blue squircle that follows the macOS icon grid (824pt body on a 1024pt canvas).
//
// Usage (from the repository root):
//   swift scripts/make_app_icon.swift
// Writes Assets/AppIcon.icns (all macOS sizes) and Assets/AppIcon.png (1024px preview).

import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Geometry (page-local design units: 440 × 560)

private let pageSize = CGSize(width: 440, height: 560)
private let pageCornerRadius: CGFloat = 34
private let foldSize: CGFloat = 118

/// Page outline with the top-right corner cut off for the dog-ear.
struct DogEarPageShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / pageSize.width
        let sy = rect.height / pageSize.height
        let r = pageCornerRadius * sx
        let fold = foldSize * sx
        let crease: CGFloat = 4 * sx
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX - fold, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + fold * (sy / sx)),
            radius: crease
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY + fold * (sy / sx)),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: crease
        )
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

/// The folded-over corner flap, lying on the page.
struct FoldFlapShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / pageSize.width
        let fold = foldSize * sx
        let inner = CGPoint(x: rect.maxX - fold, y: rect.minY + fold)
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addArc(
            tangent1End: inner,
            tangent2End: CGPoint(x: rect.maxX - fold, y: rect.minY),
            radius: 18 * sx
        )
        path.closeSubpath()
        return path
    }
}

/// Polygon in page-local design units (scaled to the page rect).
struct BandShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / pageSize.width
        let sy = rect.height / pageSize.height
        var path = Path()
        for (idx, point) in points.enumerated() {
            let mapped = CGPoint(x: rect.minX + point.x * sx, y: rect.minY + point.y * sy)
            if idx == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        path.closeSubpath()
        return path
    }
}

// Diagonal theme boundaries (slope 1.25 down-left): Day | Sepia at x=330 on the top edge,
// Sepia | Night entering the right edge at y=75 and leaving the bottom edge at x=52.
private let dayBand = [CGPoint(x: -20, y: -20), CGPoint(x: 346, y: -20), CGPoint(x: -20, y: 437.5)]
private let sepiaBand = [
    CGPoint(x: 346, y: -20), CGPoint(x: 516, y: -20), CGPoint(x: 36, y: 580), CGPoint(x: -20, y: 580), CGPoint(x: -20, y: 437.5)
]
private let nightBand = [CGPoint(x: 516, y: -20), CGPoint(x: 460, y: -20), CGPoint(x: 460, y: 580), CGPoint(x: 36, y: 580)]

private struct InkLine {
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

/// How much of the page's text survives at a given pixel size.
enum IconDetail {
    case full      // ≥ 64px: title, subtitle and body lines
    case reduced   // 32px: two bold lines
    case minimal   // 16px: theme bands only

    init(pixelSize: Int) {
        switch pixelSize {
        case ..<32: self = .minimal
        case ..<64: self = .reduced
        default: self = .full
        }
    }

    fileprivate var lines: [InkLine] {
        switch self {
        case .full:
            return [
                InkLine(y: 82, width: 172, height: 28),   // title
                InkLine(y: 134, width: 226, height: 14),  // subtitle
                InkLine(y: 196, width: 336, height: 16),
                InkLine(y: 240, width: 308, height: 16),
                InkLine(y: 284, width: 336, height: 16),
                InkLine(y: 328, width: 276, height: 16),
                InkLine(y: 372, width: 336, height: 16),
                InkLine(y: 416, width: 300, height: 16),
                InkLine(y: 460, width: 196, height: 16)
            ]
        case .reduced:
            return [InkLine(y: 150, width: 336, height: 52), InkLine(y: 300, width: 336, height: 52)]
        case .minimal:
            return []
        }
    }
}

/// Text lines drawn in one ink color (each theme band masks its own copy).
struct InkLinesView: View {
    let color: Color
    let detail: IconDetail

    var body: some View {
        GeometryReader { geo in
            let sx = geo.size.width / pageSize.width
            let sy = geo.size.height / pageSize.height
            let lines = detail.lines
            ZStack(alignment: .topLeading) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Capsule()
                        .fill(color)
                        .frame(width: line.width * sx, height: line.height * sy)
                        .offset(x: 52 * sx, y: line.y * sy)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - Icon

struct AppIconView: View {
    let detail: IconDetail

    private let dayPaper = Color(hex: 0xFFFFFF)
    private let sepiaPaper = Color(hex: 0xF3EAD0)
    private let nightPaper = Color(hex: 0x1A1B20)
    private let dayInk = Color(hex: 0x2B2D33)
    private let sepiaInk = Color(hex: 0x5C4229)
    private let nightInk = Color(hex: 0xBFBFC4)

    var body: some View {
        ZStack {
            // Squircle body (macOS icon grid: 824 × 824, continuous corners)
            RoundedRectangle(cornerRadius: 185.4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x74A6FF), Color(hex: 0x3F74F3), Color(hex: 0x2443C9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185.4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.24), Color.white.opacity(0)],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.48)
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185.4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.30), radius: 20, x: 0, y: 12)

            // Tri-theme page
            ZStack(alignment: .topLeading) {
                ZStack {
                    BandShape(points: dayBand).fill(dayPaper)
                    BandShape(points: sepiaBand).fill(sepiaPaper)
                    BandShape(points: nightBand).fill(nightPaper)

                    InkLinesView(color: dayInk, detail: detail).mask(BandShape(points: dayBand))
                    InkLinesView(color: sepiaInk, detail: detail).mask(BandShape(points: sepiaBand))
                    InkLinesView(color: nightInk, detail: detail).mask(BandShape(points: nightBand))
                }
                .clipShape(DogEarPageShape())
                // Composite first: a container's .shadow is otherwise applied to every band and line
                .compositingGroup()
                .shadow(color: Color(hex: 0x0A1B66).opacity(0.50), radius: 30, x: 0, y: 22)

                FoldFlapShape()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xDCE3F2), Color(hex: 0xFFFFFF)],
                            startPoint: UnitPoint(x: 0.73, y: 0.21),
                            endPoint: UnitPoint(x: 0.865, y: 0.105)
                        )
                    )
                    .shadow(color: Color.black.opacity(detail == .full ? 0.22 : 0), radius: 10, x: -6, y: 8)
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .scaleEffect(detail == .full ? 1.06 : 1.18)
            .offset(y: -10)
        }
        .frame(width: 1024, height: 1024)
    }
}

// MARK: - Export

@MainActor
func pngData(size: Int) -> Data {
    let renderer = ImageRenderer(content: AppIconView(detail: IconDetail(pixelSize: size)))
    renderer.scale = CGFloat(size) / 1024
    renderer.isOpaque = false
    guard let cgImage = renderer.cgImage else {
        fatalError("ImageRenderer failed at \(size)px")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed at \(size)px")
    }
    return data
}

MainActor.assumeIsolated {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let assets = root.appendingPathComponent("Assets", isDirectory: true)
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("OpenPDFExpert-AppIcon.iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

    let entries: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024)
    ]
    for (name, size) in entries {
        try! pngData(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
    }
    try! pngData(size: 1024).write(to: assets.appendingPathComponent("AppIcon.png"))

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        fatalError("iconutil failed (\(iconutil.terminationStatus))")
    }
    print("Wrote \(assets.appendingPathComponent("AppIcon.icns").path)")
}
