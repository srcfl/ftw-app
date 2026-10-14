import FTWShared
import SwiftUI
import WidgetKit

/// The plan dial's face, drawn from a `WatchDial`: price ticks coloured by
/// what the battery does, the car's dotted arc and the hand. The watch app
/// draws it large with its hours and the Crown's choice; the complication
/// draws the same face small.
///
/// Every mark is a still path filled once. Nothing glows: a plan is intent,
/// not a reading.
struct DialFace: View {
    enum Size { case app, complication }

    let dial: WatchDial
    /// The quarter the Crown chose; nil or 0 points the hand at now.
    var selected: Int? = nil
    /// The plan is old or the box could not plan: every tick in ink3.
    var grey = false
    var size: Size = .app

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let g = DialGeometry(side: side, size: size)
            ZStack {
                if size == .app {
                    Circle()
                        .stroke(Theme.ink.opacity(0.18), lineWidth: 0.5)
                        .frame(width: g.rim * 2, height: g.rim * 2)
                    HourLabels(g: g, dial: dial)
                }
                ticks(g, .waits).fill(grey ? Theme.ink3.opacity(0.45) : Theme.ink3.opacity(0.6))
                ticks(g, .gives).fill(grey ? Theme.ink3.opacity(0.45) : Theme.ink)
                ticks(g, .stores).fill(grey ? Theme.ink3.opacity(0.45) : Theme.stores)
                    .widgetAccentable()
                stubs(g).fill(Theme.ink3.opacity(0.5))
                carDots(g).fill(grey ? Theme.ink3 : Theme.car)
                    .widgetAccentable()
                if size == .app, let i = selected, i > 0 {
                    lockOn(g, i).fill(Theme.ink)
                }
                hand(g).stroke(Theme.ink, style: StrokeStyle(lineWidth: size == .app ? 1.5 : 1.2, lineCap: .round))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Paths

    /// One path per battery action, so each fills in one go.
    private func ticks(_ g: DialGeometry, _ action: WatchDial.Battery) -> Path {
        var p = Path()
        for (i, q) in dial.quarters.enumerated() where q.battery == action {
            guard let level = q.level else { continue }
            let length = g.unit * Double(level + 1)
            p.addPath(g.tick(at: dial.angle(quarter: i), from: g.inner, length: length, width: g.tickWidth * dial.fade(i).squareRoot()))
        }
        return p
    }

    /// Quarters the market has not priced yet: a short stub, never a level.
    private func stubs(_ g: DialGeometry) -> Path {
        var p = Path()
        for (i, q) in dial.quarters.enumerated() where q.minor == nil && i % 2 == 0 {
            p.addPath(g.tick(at: dial.angle(quarter: i), from: g.inner, length: g.unit * 0.6, width: g.tickWidth * 0.8))
        }
        return p
    }

    /// The car's charging: a dotted arc inside the ticks, a dot every
    /// other quarter.
    private func carDots(_ g: DialGeometry) -> Path {
        var p = Path()
        for (i, q) in dial.quarters.enumerated() where q.car && i % 2 == 0 {
            let c = g.point(dial.angle(quarter: i), g.carRadius)
            p.addEllipse(in: CGRect(x: c.x - g.dot / 2, y: c.y - g.dot / 2, width: g.dot, height: g.dot))
        }
        return p
    }

    /// The quarter the Crown chose: its tick at full length, in ink, and the
    /// phone's lock-on brackets (`LockOn`) closing on its outer end.
    private func lockOn(_ g: DialGeometry, _ i: Int) -> Path {
        let a = dial.angle(quarter: i)
        var p = g.tick(at: a, from: g.inner - g.unit * 0.8, length: g.rim - g.inner + g.unit * 0.8, width: g.tickWidth * 1.6)
        p.addPath(LockOn.brackets(around: g.point(a, g.rim - g.unit), half: g.unit * 1.6, arm: g.unit * 0.8)
            .strokedPath(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)))
        return p
    }

    private func hand(_ g: DialGeometry) -> Path {
        let a = dial.handAngle(selected: selected)
        var p = Path()
        p.move(to: g.point(a, g.inner - g.unit * 1.2))
        p.addLine(to: g.point(a, g.rim + (size == .app ? 3 : 1)))
        return p
    }
}

/// Where things sit on a dial `side` points across.
struct DialGeometry {
    let side: CGFloat
    let size: DialFace.Size

    var centre: CGPoint { CGPoint(x: side / 2, y: side / 2) }
    /// The outer edge of the dearest tick.
    var rim: CGFloat { side / 2 - (size == .app ? 11 : 1) }
    /// The hours sit just outside the rim.
    var labelRadius: CGFloat { side / 2 - 5 }
    /// Where every tick starts.
    var inner: CGFloat { rim * (size == .app ? 0.62 : 0.56) }
    /// One price level's length.
    var unit: CGFloat { (rim - inner) / CGFloat(WatchDial.levels) }
    var tickWidth: CGFloat { max(0.9, side * (size == .app ? 0.0085 : 0.012)) }
    var carRadius: CGFloat { inner - unit * (size == .app ? 1.6 : 1.4) }
    var dot: CGFloat { max(1.4, side * 0.012) }

    /// A point `r` from the centre, `a` radians clockwise from the top.
    func point(_ a: Double, _ r: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + r * CGFloat(sin(a)), y: centre.y - r * CGFloat(cos(a)))
    }

    /// A tick as a thin quad along the radius.
    func tick(at a: Double, from r0: CGFloat, length: CGFloat, width: CGFloat) -> Path {
        let half = Double(width / 2)
        let nx = CGFloat(cos(a)) * CGFloat(half), ny = CGFloat(sin(a)) * CGFloat(half)
        let p0 = point(a, r0), p1 = point(a, r0 + length)
        var p = Path()
        p.move(to: CGPoint(x: p0.x - nx, y: p0.y - ny))
        p.addLine(to: CGPoint(x: p1.x - nx, y: p1.y - ny))
        p.addLine(to: CGPoint(x: p1.x + nx, y: p1.y + ny))
        p.addLine(to: CGPoint(x: p0.x + nx, y: p0.y + ny))
        p.closeSubpath()
        return p
    }
}

/// 00, 06, 12 and 18 just outside the rim, in the terminal's mono.
private struct HourLabels: View {
    let g: DialGeometry
    let dial: WatchDial

    var body: some View {
        ForEach([0, 6, 12, 18], id: \.self) { h in
            // 00 at the bottom, 06 on the left, 12 at the top.
            let a = Double(h) / 24 * 2 * .pi + .pi
            let p = g.point(a, g.labelRadius)
            Text(verbatim: h < 10 ? "0\(h)" : "\(h)")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.ink3)
                .position(p)
        }
    }
}
