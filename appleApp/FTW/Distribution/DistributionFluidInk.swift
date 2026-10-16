#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Soft directional ink shared by the site and its detail views.
enum DistributionFluidInk {
    nonisolated static func well(at center: CGPoint, power: Double, time: Double, color: Color, draining: Bool, context: GraphicsContext) {
        guard time > 0 else { return }
        let cycle = (time * (0.22 + sqrt(power) * 0.06)).truncatingRemainder(dividingBy: 1)
        let progress = draining ? 1 - cycle : cycle
        let radius = 18 + progress * 37
        let ellipse = CGRect(x: center.x - radius, y: center.y - radius * 0.35, width: radius * 2, height: radius * 0.7)
        var ink = context
        ink.addFilter(.blur(radius: 8))
        ink.stroke(Path(ellipseIn: ellipse), with: .color(color.opacity((1 - progress) * 0.3)), lineWidth: 12)
    }

    nonisolated static func contact(finger: CGPoint, strength: Double, context: GraphicsContext) {
        let amount = max(0, min(1, strength))
        guard amount > 0.001 else { return }
        var ink = context
        ink.addFilter(.blur(radius: 3))
        let r = 32.0, rect = CGRect(x: finger.x - r, y: finger.y - r, width: r * 2, height: r * 2)
        ink.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.black.opacity(amount * 0.10), .clear]), center: finger, startRadius: 0, endRadius: r))
        ink.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(amount * 0.48)), lineWidth: 2.5)
    }

    nonisolated static func paint(_ path: Path, power: Double, time: Double, color: Color, context: GraphicsContext, scale: Double = 1) {
        let speed = 0.18 + min(0.4, sqrt(power) * 0.11)
        let width = (12 + min(32, sqrt(power) * 14)) * scale
        for offset in [0.0, 0.75] {
            let head = (time * speed + offset).truncatingRemainder(dividingBy: 1.5)
            let tail = max(0, head - 0.46), end = min(1, head)
            guard tail < end else { continue }
            let fade = max(0, min(1, head / 0.16, (1.5 - head) / 0.25))
            var ink = context
            ink.addFilter(.blur(radius: 7))
            ink.stroke(path.trimmedPath(from: tail, to: end), with: .color(color.opacity(0.38 * fade)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }

}
#endif
