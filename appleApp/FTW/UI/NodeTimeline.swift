import Accessibility
import FTWKit
import SwiftUI

/// One timeline, shared by the compact and full-screen charts. Histories
/// are already cached by the home: a gesture sends no network request.
struct TimelineChartArea: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    let scrub: ScrubModel
    @Binding var window: TimelineWindow
    let series: [EnergyNode]
    let text: PeriodText
    var onTap: (() -> Void)?
    @State private var size = CGSize.zero
    @State private var shown: YDomain?
    @State private var interacting = false
    /// The scale on screen moving to a new one, and the changes seen and
    /// rested on: the timeline runs at the display's rate only between.
    @State private var motion = ScaleMotion()
    @State private var scaleChanges = 0
    @State private var scaleSettled = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var axis: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var tag: CGFloat = 11

    private struct Input {
        var node: EnergyNode
        var history: [ChartSample]
        var observations: [LiveSample]
        var stepMs: Double
        var gapMs: Double
        var ahead: (kind: AheadPicture.Kind, slots: [AheadPicture.Mark])?
    }

    private func inputs() -> [Input] {
        let shownWindow = self.shownWindow
        _ = home.nodes.live.revision
        return series.map { n in
            let points = home.nodes.live.samples(n, sinceMs: site.nowMs - LiveTrace.windowMs)
            let period = LiveSeries.period(of: points) ?? 1_000
            let step = n == .car ? 3_600_000 : (home.nodes.history.frame?.stepMs ?? 300_000)
            var history = NodeHistory.samples(n, home: home, fromMs: shownWindow.fromMs - 3_600_000)
            if history.isEmpty, n != .car, !home.nodes.history.loaded, home.nodes.history.problem == nil {
                let first = (shownWindow.fromMs / 300_000).rounded(.down) * 300_000
                history = stride(from: first, to: min(shownWindow.toMs, site.nowMs), by: 300_000).map { ChartSample(startMs: $0, value: nil, fetching: true) }
            }
            history = history.map { sample in
                sample.startMs + step <= site.nowMs ? sample : ChartSample(startMs: sample.startMs, value: nil, fetching: true)
            }
            return Input(node: n, history: history, observations: points,
                         stepMs: step,
                         gapMs: max(site.readingGapMs, LiveSeries.joinPeriods * period),
                         ahead: NodeHistory.ahead(n, home: home, nowMs: site.nowMs))
        }
    }

    private func frame(_ domain: YDomain?) -> ChartFrame {
        ChartFrame(top: tag * 1.35 + 8, bottom: axis * 1.4 + 4, trailing: ChartAxes.gutter(domain, axis: axis))
    }

    private func picture(_ inputs: [Input], size: CGSize) -> HistoryPicture {
        let shownWindow = self.shownWindow
        let values = inputs.flatMap { $0.observations.filter { $0.t >= shownWindow.fromMs && $0.t <= min(shownWindow.toMs, site.nowMs) }.map(\.v) }
        let extent = values.min().flatMap { lo in values.max().map { lo...$0 } }
        let words = ReadoutWords(value: { AppWords.power(abs($0)) }, range: { "\(AppWords.power(abs($0)))–\(AppWords.power(abs($1)))" }, none: L("no data"))
        var picture = HistoryPicture.build(inputs.map { ($0.node.rawValue, $0.history) },
            ahead: Dictionary(uniqueKeysWithValues: inputs.compactMap { i in i.ahead.map { (i.node.rawValue, $0) } }),
            fromMs: shownWindow.fromMs, toMs: shownWindow.toMs, nowMs: drawNow(width: size.width), size: size, previous: shown,
            floor: node.scaleFloorW(), clock: .of(.current), everyHours: shownWindow.spanMs > 24 * 3_600_000 ? 12 : max(1, Int(shownWindow.spanMs / (4 * 3_600_000))),
            observationExtent: extent, sampleSteps: Dictionary(uniqueKeysWithValues: inputs.map { ($0.node.rawValue, $0.stepMs) }), words: words)
        // At short scales labels need minutes, and at long ones the date.
        let span = shownWindow.spanMs
        let step = span <= 10 * 60_000 ? 60_000.0 : span <= 30 * 60_000 ? 300_000.0 : span <= 3_600_000 ? 900_000.0
            : span <= 6 * 3_600_000 ? 3_600_000.0 : span <= 24 * 3_600_000 ? 6 * 3_600_000.0 : 12 * 3_600_000.0
        let clock = ZoneClock.of(.current)
        var at = clock.alignDown(shownWindow.fromMs + step, stepMs: step)
        picture.ticks = []
        while at < shownWindow.toMs - shownWindow.spanMs * 0.04 {
            let label = shownWindow.spanMs >= 24 * 3_600_000 && clock.minuteOfDay(at) == 0
                ? Date(timeIntervalSince1970: at / 1000).formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: AppWords.language == .sv ? "sv_SE" : "en_US")))
                : clock.label(at)
            picture.ticks.append(.init(ms: at, label: label))
            // The next tick on the clock, not a fixed step of elapsed time,
            // so 06:00 stays 06:00 the night the clock turns.
            at = clock.alignDown(at + step * 1.5, stepMs: step)
        }
        for i in picture.layers.indices {
            guard var ghost = picture.layers[i].ghost, ghost.kind == .forecast,
                  let input = inputs.first(where: { $0.node.rawValue == picture.layers[i].key }), let ahead = input.ahead else { continue }
            ghost.line = AheadPicture.forecastLine(ahead.slots, fromMs: shownWindow.fromMs, toMs: shownWindow.toMs, domain: picture.domain, size: size, intervalMeans: true, notBeforeMs: drawNow(width: size.width))
            picture.layers[i].ghost = ghost
        }
        return picture
    }

    var body: some View {
        let data = inputs()
        let initial = frame(shown)
        let first = picture(data, size: initial.plot(in: size).size)
        let frame = frame(first.domain)
        let plot = frame.plot(in: size)
        let picture = frame == initial ? first : picture(data, size: plot.size)
        let traces = Dictionary(uniqueKeysWithValues: data.compactMap { input -> (String, LiveSeries)? in
            let points = input.observations.filter { $0.t <= site.nowMs }
            guard !points.isEmpty else { return nil }
            let trace = LiveSeries.build(points, sourceGapMs: input.gapMs, windowMs: shownWindow.spanMs, nowMs: shownWindow.toMs, size: plot.size, inset: 0)
            return trace.readings.isEmpty ? nil : (input.node.rawValue, trace)
        })
        let looks = Dictionary(uniqueKeysWithValues: data.map { ($0.node.rawValue, NodeChartLook.look($0.node)) })
        let live = Set(data.filter { site.freshness($0.node).live }.map { $0.node.rawValue })
        let empty = emptyMessage(data)
        chart(data, picture: picture, traces: traces, frame: frame, looks: looks, live: live, empty: empty)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: picture.domain, initial: true) {
            shown = picture.domain
            // Only a scale that moves runs the timeline: the first, and any
            // under Reduce Motion, are there at once.
            if motion.target(picture.domain, at: Date.timeIntervalSinceReferenceDate, still: reduceMotion) { scaleChanges += 1 }
        }
        .modifier(TimelineAccessibility(node: node, window: $window, shown: shownWindow, nowMs: site.nowMs,
            empty: empty, history: picture, observations: traces[node.rawValue]?.readings ?? [],
            sampleMs: data.first(where: { $0.node == node })?.stepMs ?? 300_000))
    }

    /// The window as drawn: the stored one while a finger is on it, else
    /// the stored one carried along with now. Nothing here writes it back,
    /// so a reading redraws once, and a chart under the full-screen cover
    /// moves nothing under the finger on it.
    private var shownWindow: TimelineWindow {
        interacting ? window : window.following(nowMs: site.nowMs, clock: .of(.current))
    }

    /// Now on the plot's own grain, one point of time: the history picture
    /// holds still between readings that move now by less than a point.
    private func drawNow(width: CGFloat) -> Double {
        let q = max(1_000, shownWindow.spanMs / Double(max(1, width)))
        return (site.nowMs / q).rounded(.down) * q
    }

    private func chart(_ data: [Input], picture: HistoryPicture, traces: [String: LiveSeries], frame: ChartFrame, looks: [String: TraceLook], live: Set<String>, empty: String?) -> some View {
        ZStack {
            // A new scale springs in from the one on screen and the timeline
            // runs until it rests on it; between changes the timeline rests
            // and the surface draws on data. The lines and the finger's dot
            // read the same scale on every frame.
            let moving = scaleSettled != scaleChanges
            TimelineView(.animation(paused: !moving)) { tick in
                let scale = motion.shown(at: (moving ? tick.date : Date()).timeIntervalSinceReferenceDate)
                ZStack {
                    ChartSurface(drawing: TimelineDrawing(history: picture, traces: traces, looks: looks, frame: frame, liveKeys: live, nowMs: site.nowMs, shown: scale, axis: axis, words: ChartLabels(fetching: L("Waiting for history"), now: L("NOW"))))
                        .equatable()
                    TimelineTouchOverlay(window: $window, shown: shownWindow, nowMs: site.nowMs, frame: frame, domain: scale ?? picture.domain, scrub: scrub, text: text, node: node,
                        reading: { ms in
                            // The own series, or the first chosen when its chip is
                            // off; the words and the colour are that series'.
                            guard let own = data.first(where: { $0.node == node }) ?? data.first else { return (node, .missing) }
                            return (own.node, TimelineReading.at(ms, history: own.history, sampleMs: own.stepMs, observations: own.observations, gapMs: own.gapMs, nowMs: site.nowMs, ahead: own.ahead))
                        }, onTap: onTap, touchingChanged: { interacting = $0 })
                }
                .onChange(of: tick.date) { if motion.resting { scaleSettled = scaleChanges } }
            }
            if let message = empty {
                Text(message).font(.footnote).foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                    .allowsHitTesting(false)
            }
        }
    }

    private func emptyMessage(_ inputs: [Input]) -> String? {
        let shownWindow = self.shownWindow
        guard let own = inputs.first(where: { $0.node == node }) else { return nil }
        let end = min(shownWindow.toMs, site.nowMs)
        if shownWindow.fromMs >= site.nowMs {
            return own.ahead?.slots.contains(where: { $0.startMs < shownWindow.toMs && $0.endMs > shownWindow.fromMs }) == true ? nil
                : (TimelineWords.planned(own.node) ? L("No plan for this time.") : L("No forecast for this time."))
        }
        let hasHistory = own.history.contains { $0.value != nil && $0.startMs < end && $0.startMs + own.stepMs > shownWindow.fromMs }
        let hasObservation = own.observations.contains { $0.t >= shownWindow.fromMs && $0.t <= end }
        guard !hasHistory, !hasObservation else { return nil }
        let problem = node == .car ? home.nodes.carEnergy.problem : home.nodes.history.problem
        let loaded = node == .car ? home.nodes.carEnergy.loaded : home.nodes.history.loaded
        if let problem { return problem }
        if !loaded { return L("Fetching history…") }
        if own.history.contains(where: { $0.fetching && $0.startMs < end && $0.startMs + own.stepMs > shownWindow.fromMs }) { return L("Waiting for history") }
        return L("No recorded history in this window.")
    }
}

private struct TimelineAccessibility: ViewModifier {
    let node: EnergyNode
    @Binding var window: TimelineWindow
    let shown: TimelineWindow
    let nowMs: Double
    let empty: String?
    let history: HistoryPicture
    let observations: [LiveSample]
    let sampleMs: Double

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(node.title + ". " + L("History and live readings"))
            .accessibilityValue(TimelineLabel.window(shown, nowMs: nowMs, clock: .of(.current)) + (empty.map { ". " + $0 } ?? ""))
            .accessibilityHint(L("Swipe up or down to move through time. Actions change the zoom."))
            .accessibilityAdjustableAction(adjust)
            .accessibilityAction(named: Text(L("Zoom in"))) { zoom(2) }
            .accessibilityAction(named: Text(L("Zoom out"))) { zoom(0.5) }
            .accessibilityAction(named: Text(L("Today"))) { window.returnToToday(nowMs: nowMs, clock: .of(.current)) }
            .accessibilityChartDescriptor(TimelineDescriptor(node: node, history: history, observations: observations, sampleMs: sampleMs))
            .accessibilityIdentifier("node.timeline.chart")
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let destination: Double
        switch direction {
        case .increment: destination = -0.25
        case .decrement: destination = 0.25
        @unknown default: return
        }
        window = shown.transformed(anchor: 0, destination: destination, magnification: 1, nowMs: nowMs)
    }

    private func zoom(_ factor: Double) {
        window = shown.transformed(anchor: 0.5, destination: 0.5, magnification: factor, nowMs: nowMs)
    }
}

/// Touches redraw this small overlay, not the chart geometry. A quick
/// drag pans; a hold reads. Two fingers move and zoom around their own
/// centroid. Starting at the leading edge leaves the system back gesture.
private struct TimelineTouchOverlay: View {
    @Binding var window: TimelineWindow
    /// The window as drawn when the finger lands; the gesture starts from
    /// it, so a window that was following now does not jump back.
    let shown: TimelineWindow
    let nowMs: Double
    let frame: ChartFrame
    let domain: YDomain
    let scrub: ScrubModel
    let text: PeriodText
    let node: EnergyNode
    let reading: (Double) -> (node: EnergyNode, value: TimelineReading)
    var onTap: (() -> Void)?
    var touchingChanged: (Bool) -> Void
    @State private var size = CGSize.zero
    @State private var start: Touch?
    @State private var selectedMs: Double?
    @GestureState private var touching = false

    private struct Touch {
        var window: TimelineWindow
        var positions: [CGFloat]
        var began: Date
        var lastX: CGFloat
        // 0 waits for intent, 1 pans, 2 reads, 3 zooms.
        var mode = 0
        /// Panned, read, zoomed or had a second finger: never a tap.
        var acted = false
    }

    var body: some View {
        Canvas { g, size in
            guard scrub.isDown, let selectedMs else { return }
            let plot = frame.plot(in: size)
            let x = plot.minX + CGFloat((selectedMs - window.fromMs) / window.spanMs) * plot.width
            let px = 1 / max(1, g.environment.displayScale)
            LockOn.rule(at: x, plot: plot, px: px, in: &g)
            let (from, value) = reading(selectedMs)
            if let watts = value.watts {
                let y = plot.minY + YMap(domain: domain, height: plot.height).y(watts)
                LockOn.dot(at: CGPoint(x: x, y: y), color: NodeChartLook.color(from), in: &g)
            }
            let whose = from == node ? "" : from.title + " · "
            LockOn.tag(whose + TimelineWords.reading(value, atMs: selectedMs), over: x, plot: plot, size: 10, in: &g, canvas: size)
        }
        .leavesTheEdge()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .gesture(SpatialEventGesture()
            .updating($touching) { _, state, _ in state = true }
            .onChanged { events in
                let positions = events.filter { $0.phase == .active }.map { $0.location.x }.sorted()
                guard !positions.isEmpty, size.width > frame.trailing else { return }
                if start == nil || start?.positions.count != positions.count {
                    scrub.lift()
                    // A changed finger count keeps the gesture from being a
                    // tap, so a pinch never ends by opening the full screen.
                    let acted = start != nil || positions.count >= 2
                    let from = start == nil ? shown : window
                    window = from
                    start = Touch(window: from, positions: positions, began: Date(), lastX: positions[0], acted: acted)
                    return
                }
                guard var saved = start else { return }
                let width = size.width - frame.trailing
                if positions.count >= 2 {
                    saved.mode = 3
                    saved.acted = true
                    let oldSpan = max(1, saved.positions.last! - saved.positions[0])
                    let nextSpan = max(1, positions.last! - positions[0])
                    let anchor = Double((saved.positions[0] + saved.positions.last!) / 2 / width)
                    let destination = Double((positions[0] + positions.last!) / 2 / width)
                    window = saved.window.transformed(anchor: anchor, destination: destination, magnification: Double(nextSpan / oldSpan), nowMs: nowMs)
                    scrub.lift()
                } else if saved.mode == 2 {
                    read(positions[0])
                } else if abs(positions[0] - saved.positions[0]) >= 6 {
                    saved.mode = 1
                    saved.acted = true
                    window = saved.window.transformed(anchor: Double(saved.positions[0] / width), destination: Double(positions[0] / width), magnification: 1, nowMs: nowMs)
                }
                saved.lastX = positions[0]
                start = saved
            }
            .onEnded { _ in
                if let s = start, s.mode == 0, !s.acted { onTap?() }
                end()
            })
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.25, maximumDistance: 6).onEnded { _ in
            guard var saved = start, saved.positions.count == 1, saved.mode == 0 else { return }
            saved.mode = 2
            saved.acted = true
            start = saved
            read(saved.lastX)
        })
        // Two fingers here zoom time; the view's zoom transition may not
        // take them to pinch the view closed.
        .gesture(ChartPinchGuard(touching: touching))
        .onChange(of: touching) { _, down in
            // Held from where it was drawn, so nothing moves under the finger.
            if down { window = shown }
            touchingChanged(down)
            if !down { end() }
        }
    }

    private func read(_ x: CGFloat) {
        let fraction = Double(min(max(x / max(1, size.width - frame.trailing), 0), 1))
        let ms = window.time(at: fraction)
        selectedMs = ms
        let (from, value) = reading(ms)
        // Another series than the view's own says whose it is, so the
        // battery's plan never reads as the home's under "Usage".
        let whose = from == node ? "" : from.title + " · "
        let words = whose + TimelineWords.reading(value, atMs: ms)
        let watts = value.watts
        // The hero's one line: a series of the view's own gives its time,
        // another its name instead, the time being on the tag.
        let hero = from == node ? TimelineWords.when(value, node: from, atMs: ms) : from.title + TimelineWords.kind(value, node: from)
        text.set([words], spans: { _ in words }, heroes: [.init(watts: watts.map(abs), signed: watts ?? 0, word: hero, node: from)])
        scrub.move(to: 0, landmark: false)
    }

    private func end() {
        start = nil
        selectedMs = nil
        scrub.lift()
    }
}

/// Under the chart, two lines: what the window shows ("Today",
/// "Yesterday 18:00 – Today 06:00") with the way back to today once it has
/// moved, and what the past in it adds up to, or under a finger the
/// reading there.
struct TimelineControls: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    @Binding var window: TimelineWindow
    let scrub: ScrubModel
    let text: PeriodText
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The window as the chart draws it, carried along with now.
    private var shown: TimelineWindow { window.following(nowMs: site.nowMs, clock: .of(.current)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(TimelineLabel.window(shown, nowMs: site.minuteMs, clock: .of(.current)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                Button {
                    withAnimation(Theme.spring) { window.returnToToday(nowMs: site.nowMs, clock: .of(.current)) }
                } label: {
                    Label(L("Today"), systemImage: "arrow.uturn.backward")
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.quiet)
                .opacity(window.isToday ? 0 : 1)
                .disabled(window.isToday)
                .accessibilityHidden(window.isToday)
                .accessibilityIdentifier("timeline.today")
            }
            Group {
                if typeSize.isAccessibilitySize { readout.fixedSize(horizontal: false, vertical: true) }
                else { readout.lineLimit(2, reservesSpace: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chart.readout")
        }
        .animation(Theme.spring, value: window.isToday)
    }

    private var readout: some View {
        Text(summary).font(.subheadline).foregroundStyle(Theme.ink2).monospacedDigit()
    }

    /// What the box recorded in the window's past, in the node's words, and
    /// what is missing from it. A window wholly ahead says it is the plan.
    private var summary: String {
        let problem = node == .car ? home.nodes.carEnergy.problem : home.nodes.history.problem
        let loaded = node == .car ? home.nodes.carEnergy.loaded : home.nodes.history.loaded
        if let problem { return problem }
        let window = shown
        guard window.fromMs < site.nowMs else { return TimelineWords.planned(node) ? L("What FTW plans, not measured.") : L("What FTW forecasts, not measured.") }
        let samples = NodeHistory.samples(node, home: home, fromMs: window.fromMs - 3_600_000)
        let step = node == .car ? 3_600_000 : (home.nodes.history.frame?.stepMs ?? 300_000)
        let energy = TimelineEnergy.recorded(samples, sampleMs: step, fromMs: window.fromMs, toMs: window.toMs, nowMs: site.nowMs)
        guard energy.knownMs > 0 else { return loaded ? L("No recorded energy in this window.") : L("Fetching history…") }
        let line = DayWords.line(node, inWh: energy.inWh, outWh: energy.outWh)
        var words = (energy.prorated ? "≈ " : "") + line
        // "So far: charged …", the sentence's own first word in lower case.
        if window.toMs > site.nowMs { words = NodeWords.format("So far: %@", (energy.prorated ? "≈ " : "") + line.prefix(1).lowercased() + line.dropFirst()) }
        if energy.missingMs >= 600_000 {
            let minutes = Int((energy.missingMs / 60_000).rounded())
            words += " · " + NodeWords.format("%@ not recorded", minutes < 120 ? "\(minutes) min" : "\(minutes / 60) h")
        }
        return words
    }
}

struct TimelineFullScreen: View {
    let site: SiteModel
    let node: EnergyNode
    let home: HomeModels
    @Binding var window: TimelineWindow
    @Binding var series: [EnergyNode]
    @State private var scrub = ScrubModel()
    @State private var text = PeriodText()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            Group {
                if typeSize.isAccessibilitySize { ScrollView { content(height: 360) } }
                else { content(height: nil) }
            }
            .background(Theme.ground)
            .navigationTitle(node.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("node.chart.close") } }
        }
    }

    private func content(height: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NodeHero(site: site, node: node, home: home, scrub: scrub, text: text).padding(.horizontal, 20)
            SeriesChips(own: node, available: NodeView.chartable(node), chosen: $series).padding(.horizontal, 14)
            TimelineChartArea(site: site, node: node, home: home, scrub: scrub, window: $window, series: series, text: text)
                .frame(height: height).frame(maxHeight: height == nil ? .infinity : nil).padding(.horizontal, 4)
            TimelineControls(site: site, node: node, home: home, window: $window, scrub: scrub, text: text).padding(.horizontal, 20).padding(.bottom, 16)
            NodeFooter(site: site, node: node, live: home.nodes.live, titleSaysAge: false).padding(.horizontal, 20).padding(.bottom, 8)
        }
    }
}

private enum TimelineWords {
    /// What FTW decides is planned: the battery, the car, and the grid,
    /// which is what those plans leave over. The home's use and the sun
    /// cannot be planned, only forecast (Fredrik, 24 October 2026).
    static func planned(_ node: EnergyNode) -> Bool {
        switch node {
        case .battery, .car, .grid: return true
        case .home, .solar: return false
        }
    }

    static func material(_ node: EnergyNode, sampleMs: Double) -> String {
        switch node {
        case .car, .battery, .grid: NodeWords.timelineMaterial(sampleMs: sampleMs, planned: true)
        case .home, .solar: NodeWords.timelineMaterial(sampleMs: sampleMs, planned: false)
        }
    }

    /// The hero's word under a finger: when, what kind if it is not
    /// measured, and which way it ran, "21:30–21:45 · plan · charging". The
    /// figure says the power.
    static func when(_ value: TimelineReading, node: EnergyNode, atMs: Double) -> String {
        let way = value.watts.map { " · " + Readouts.word(node, $0) } ?? ""
        switch value {
        case let .observation(at, _, seen): return Readouts.seconds(at) + (seen ? "" : " · " + L("saved")) + way
        case let .mean(start, end, _): return Readouts.span(start, end) + way
        case let .forecast(start, end, _): return Readouts.span(start, end) + " · " + L("forecast") + way
        case let .plan(start, end, _): return Readouts.span(start, end) + " · " + L("plan") + way
        case .fetching: return Readouts.clock(atMs) + " · " + L("Waiting for history")
        case .missing: return Readouts.clock(atMs) + " · " + L("no data")
        }
    }

    /// What kind and which way, without the time: " · plan · charging".
    static func kind(_ value: TimelineReading, node: EnergyNode) -> String {
        let way = value.watts.map { " · " + Readouts.word(node, $0) } ?? ""
        switch value {
        case .observation(_, _, let seen): return (seen ? "" : " · " + L("saved")) + way
        case .mean: return way
        case .forecast: return " · " + L("forecast") + way
        case .plan: return " · " + L("plan") + way
        case .fetching: return " · " + L("Waiting for history")
        case .missing: return " · " + L("no data")
        }
    }

    static func reading(_ value: TimelineReading, atMs: Double) -> String {
        switch value {
        case let .observation(at, watts, seen):
            return Readouts.seconds(at) + " · " + (seen ? "" : L("saved") + " ") + AppWords.power(abs(watts))
        case let .mean(start, end, watts):
            return Readouts.span(start, end) + " · " + AppWords.power(abs(watts))
        case let .forecast(start, end, watts):
            return Readouts.span(start, end) + " · " + L("forecast") + " " + AppWords.power(abs(watts))
        case let .plan(start, end, watts):
            return Readouts.span(start, end) + " · " + L("plan") + " " + AppWords.power(abs(watts))
        case .fetching: return Readouts.clock(atMs) + " · " + L("Waiting for history")
        case .missing: return Readouts.clock(atMs) + " · " + L("no data")
        }
    }
}

private struct TimelineDescriptor: AXChartDescriptorRepresentable {
    let node: EnergyNode
    let history: HistoryPicture
    let observations: [LiveSample]
    let sampleMs: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let grid = history.grid
        let x = AXNumericDataAxisDescriptor(title: L("Time"), range: grid.fromMs...max(grid.fromMs + 1, grid.toMs), gridlinePositions: []) { Readouts.clock($0) }
        let y = AXNumericDataAxisDescriptor(title: L("Power"), range: history.domain.lower...max(history.domain.lower + 1, history.domain.upper), gridlinePositions: []) { AppWords.power(abs($0)) }
        let means = history.layers.first?.series.buckets ?? []
        let stored = AXDataSeriesDescriptor(name: L("interval mean"), isContinuous: false, dataPoints: means.compactMap { b in b.mean.map { AXDataPoint(x: b.atMs, y: $0) } })
        let readings = AXDataSeriesDescriptor(name: L("source reading"), isContinuous: false, dataPoints: observations.map { AXDataPoint(x: $0.t, y: $0.v) })
        var series = [stored, readings]
        if let ghost = history.layers.first?.ghost {
            let kind = ghost.kind == .plan ? L("planned") : L("forecast")
            let points = ghost.values.indices.compactMap { i -> AXDataPoint? in
                let at = max(ghost.grid.startMs(i), history.nowMs ?? ghost.grid.fromMs)
                guard at < ghost.grid.toMs, let watts = ghost.values[i] else { return nil }
                return AXDataPoint(x: at, y: watts, additionalValues: [], label: kind)
            }
            series.append(AXDataSeriesDescriptor(name: kind, isContinuous: false, dataPoints: points))
        }
        return AXChartDescriptor(title: node.title, summary: TimelineWords.material(node, sampleMs: sampleMs), xAxis: x, yAxis: y, additionalAxes: [], series: series)
    }
}
