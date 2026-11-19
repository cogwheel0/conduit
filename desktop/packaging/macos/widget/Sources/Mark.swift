// The brand mark (desktop/crates/components/assets/brand/mark.svg): an
// open C tilted towards a dot, on a 24-point grid.

import SwiftUI

struct ConduitMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let origin = CGPoint(
                x: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
            }
            // `M17.6 6.2 A8 8 0 1 0 19.4 15`: the long way round a circle
            // of radius 8 about (12, 12), anticlockwise on screen.
            let center = point(12, 12)
            let start = atan2(6.2 - 12, 17.6 - 12)
            let end = atan2(15 - 12, 19.4 - 12)
            var arc = Path()
            arc.addArc(
                center: center, radius: 8 * scale, startAngle: .radians(start),
                endAngle: .radians(end), clockwise: true)
            context.stroke(
                arc, with: .foreground,
                style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round))
            let dot = Path(
                ellipseIn: CGRect(
                    x: origin.x + (16.4 - 2) * scale, y: origin.y + (11.6 - 2) * scale,
                    width: 4 * scale, height: 4 * scale))
            context.fill(dot, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
