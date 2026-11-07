import SwiftUI

/// An open-bottom tab outline: its feet join the group's baseline without drawing a second line.
struct TabContour: Shape {
    func path(in rect: CGRect) -> Path {
        let baseline = rect.maxY - 1
        let top = rect.minY + 6
        let left = rect.minX + 6
        let right = rect.maxX - 6
        let radius: CGFloat = 8
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: baseline))
        path.addQuadCurve(to: CGPoint(x: left, y: baseline - 6),
                          control: CGPoint(x: left, y: baseline))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: top),
                          control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + radius),
                          control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: baseline - 6))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: baseline),
                          control: CGPoint(x: right, y: baseline))
        return path
    }
}
