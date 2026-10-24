import SwiftUI

/// A level as a ring, the detail views' half of Ring / Quiet: a faint track
/// all round, and the level lit clockwise from twelve o'clock. The lit arc
/// takes the node's colour only for a reading that is live, or for a level
/// that is a fact though not a live reading, such as the car's (`glows`
/// false); a level FTW assumes is ink. It glows only while live, in the
/// dark, and never with Reduce Transparency. A goal, such as the car's, is
/// a short mark across the ring. What sits in the middle is the caller's.
/// A new level turns the arc with the app's spring.
struct LevelRing<Middle: View>: View {
    let pct: Double
    var goalPct: Double?
    let tint: Color
    /// The colour is earned: a live reading, or a level the box knows.
    let lit: Bool
    /// Glows while lit, as a live reading does; a fact that is not live
    /// takes its colour and no glow.
    var glows = true
    let thickness: CGFloat
    @ViewBuilder var middle: Middle
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let arc = LevelArc(fraction: pct / 100)
        let style = StrokeStyle(lineWidth: thickness, lineCap: .round)
        ZStack {
            Circle()
                .stroke(Theme.ink.opacity(scheme == .dark ? 0.13 : 0.09), lineWidth: thickness)
            if lit && glows && scheme == .dark && !reduceTransparency {
                arc.stroke(tint.opacity(0.12), style: StrokeStyle(lineWidth: thickness * 2.8, lineCap: .round))
                arc.stroke(tint.opacity(0.25), style: StrokeStyle(lineWidth: thickness * 1.8, lineCap: .round))
            }
            arc.stroke(lit ? tint : Theme.ink3, style: style)
            if let goalPct {
                GoalMark(fraction: goalPct / 100, reach: thickness)
                    .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            middle
        }
        // The stroke and a goal's mark stay inside the frame it is given,
        // and the ring keeps its size whether a goal comes or goes.
        .padding(thickness + 1)
        .animation(Theme.spring, value: pct)
        .animation(Theme.spring, value: goalPct)
    }
}

/// The lit part, clockwise from twelve o'clock.
private struct LevelArc: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = min(1, max(0, fraction))
        guard f > 0.001 else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
        return p
    }
}

/// A goal: a short line across the ring at its level.
private struct GoalMark: Shape {
    var fraction: Double
    let reach: CGFloat
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let a = (-90 + 360 * min(1, max(0, fraction))) * .pi / 180
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x + (r - reach) * cos(a), y: c.y + (r - reach) * sin(a)))
        p.addLine(to: CGPoint(x: c.x + (r + reach) * cos(a), y: c.y + (r + reach) * sin(a)))
        return p
    }
}
