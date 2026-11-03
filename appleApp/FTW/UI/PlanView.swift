import Charts
import FTWKit
import SwiftUI

/// The plan, opened from Now: half a day round the plan dial, a clock, the
/// half holding now first and the ones after a swipe away, or
/// the whole plan the box sent in lanes (to tomorrow's last priced quarter
/// in the evening), then each thing the box means to do,
/// when, and why, in the box's own reasons. The dial is the default; the
/// lanes are one tap away in the toolbar, and the phone keeps the viewer's
/// choice.
struct PlanView: View {
    let app: AppModel
    let home: HomeModels
    @State private var choosingMode = false
    /// The viewer's own choice, kept on this phone. `-FTWPlanStyle lanes`
    /// at launch holds it there, for screenshots and tests.
    @AppStorage("FTWPlanStyle") private var style: PlanStyle = .dial
    /// A finger scrubs the dial or the strip: the page holds still under it.
    @State private var dialHolds = false
    @State private var dialTouch = DialTouch()

    private var models: NodeModels { home.nodes }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlanBody(site: home.site, models: models, loadpoints: home.loadpoints, prices: home.prices, style: style, chooseMode: { choosingMode = true }, dialHolds: $dialHolds, dialTouch: dialTouch) { levers in
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(levers ? PlanBody.leversID : PlanBody.topID, anchor: levers ? .bottom : .top) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(dialHolds)
            // Every touch, beside the scroll, for the dial's ring: a
            // gesture on the ring itself stops the page scrolling. None
            // from the screen's leading 20 pt, which are the back swipe's.
            .leavesTheEdge()
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { dialTouch.change($0) }
                    .onEnded { _ in dialTouch.end() }
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.ground)
        .navigationTitle(PlanGlance.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker(L("Show the plan as"), selection: $style.animation(.easeInOut(duration: 0.25))) {
                    ForEach(PlanStyle.allCases, id: \.self) { s in
                        Image(systemName: s.symbol)
                            .accessibilityLabel(s.label)
                            .tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("plan.style")
            }
        }
        .onAppear {
            // The forecast gives the dial its sky: the same read the sun's
            // and the home's views make.
            models.plan.activate(forecast: true)
            models.mode.activate()
            home.prices.activate()
            LaunchClock.mark("first content")
        }
        .onDisappear {
            models.plan.deactivate(forecast: true)
            models.mode.deactivate()
            home.prices.deactivate()
        }
        // A command answers once, when the box says what it did: here, so it
        // plays with the mode sheet open or closed, and only here.
        .sensoryFeedback(trigger: models.mode.outcome?.tone) { _, tone in ModeSheet.feedback(tone) }
        .sheet(isPresented: $choosingMode) {
            ModeSheet(mode: models.mode, plan: models.planShare)
        }
    }
}

/// How the plan view draws the plan: round on the dial, or straight in
/// lanes.
enum PlanStyle: String, CaseIterable {
    case dial, lanes

    var label: String {
        switch self {
        case .dial: return L("Dial")
        case .lanes: return L("Lanes")
        }
    }

    var symbol: String {
        switch self {
        case .dial: return "circle.dashed"
        case .lanes: return "chart.bar.xaxis"
        }
    }
}

private struct PlanBody: View {
    let site: SiteModel
    let models: NodeModels
    let loadpoints: LoadpointsModel
    let prices: PriceModel
    let style: PlanStyle
    let chooseMode: () -> Void
    @Binding var dialHolds: Bool
    let dialTouch: DialTouch
    /// Scrolls to the levers, or back to the plan, for the style scale's
    /// recording.
    let reveal: (Bool) -> Void
    @State private var dials = DialMemo()
    @State private var strips = StripMemo()
    /// The pass a tap chose on the strip, lit on the dial too.
    @State private var chosenID: String?
    /// The half day the dial shows, 0 for the one holding now.
    @State private var face = 0
    @AppStorage(PriceShown.feesKey) private var fees = true
    @AppStorage(PriceShown.vatKey) private var vat = true
    @Namespace private var zoom

    static let topID = "plan.top"
    static let leversID = "plan.levers"

    var body: some View {
        // The plan marks the minute: it redraws once a minute, not a second.
        // The lanes show the whole plan the box sent; the dial half a day,
        // as on a clock.
        let minute = site.minuteMs
        let moment = models.planShare.moment(nowMs: minute, whole: style == .lanes)
        let moved = models.planShare.moved
        let entry = models.planShare.entry
        let quarters = Int(((moment.toMs - minute) / PlanStrip.quarterMs).rounded(.up)) + 1
        // The price this phone chose to show, in the strip and its header.
        let choice = PriceShown(fees: fees, vat: vat)
        let window = prices.prices.map(choice.apply)
        let strip = strips.strip(entry, moment: moment, hasCar: !loadpoints.points.isEmpty, quarters: style == .lanes ? quarters : PlanStrip.count, prices: window?.slots)
        let chosen = strip.passes.first { $0.id == chosenID } ?? PlanPass.opening(strip.passes)
        let faces = dials.faces(entry, nowMs: minute)
        let shown = min(face, faces.count - 2)
        let dial = style == .dial ? dials.dial(entry, nowMs: minute, page: shown) : nil
        Group {
            switch style {
            case .dial:
                if let dial {
                    VStack(spacing: 6) {
                        PlanDialCard(dial: dial, grey: moment.isGrey, fade: DialFade.make(models.planShare.before, dial: dial, nowMs: minute), lit: chosen.map { $0.startMs...$0.endMs }, holds: $dialHolds, face: $face, faces: faces.count - 1, touch: dialTouch)
                        FaceDots(count: faces.count - 1, face: $face, name: dial.faceName)
                    }
                    .transition(.opacity)
                }
            case .lanes:
                VStack(alignment: .leading, spacing: 4) {
                    Text(moment.summary)
                        .font(.headline)
                        .foregroundStyle(moment.isGrey ? Theme.fgDim : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                        .redacted(reason: moment.placeholder ? .placeholder : [])
                    Text(stateLine(moment))
                        .font(.footnote)
                        .foregroundStyle(moment.state == .boxStale ? Theme.alarm : Theme.fgDim)
                }
                .transition(.opacity)
            }
        }
        .id(Self.topID)
        // When now passes noon or midnight, the dial starts again on now's
        // half day.
        .onChange(of: faces.first) { face = 0 }
        // The same strip as Now's, under the dial or as the lanes: the
        // passes, the price from zero, and the chosen pass's figures. On the
        // lanes it runs the whole plan, with the battery's level.
        VStack(alignment: .leading, spacing: 10) {
            PlanStripView(
                strip: strip,
                sentence: moment.nextText,
                shorter: moment.nextShorter,
                placeholder: moment.placeholder,
                priceNow: priceNow(window, minute),
                unit: PriceUnits.unit(prices.prices?.currency).label.uppercased(),
                zoom: zoom,
                chosenID: $chosenID,
                opensPlan: false,
                levelHeight: style == .lanes ? 50 : 0,
                leastPrice: 56,
                priceLabel: window.map { PriceShown.label(choice.kind(vatPermille: $0.vatPermille)) },
                touch: dialTouch,
                holds: $dialHolds,
                site: site
            )
            .equatable()
            .fitCap(.xLarge)
            Legend(sun: dial.map { !$0.sun.isEmpty } ?? false, level: style == .lanes && strip.levelPct.contains { $0 != nil })
            MovedLine(text: moved)
            // Mono stops growing at accessibility1.
            Group {
                if let cheapest = dial?.cheapestText {
                    Text(cheapest).foregroundStyle(Theme.ink2)
                }
                // What the planner reckons the plan saves, only where it
                // compares honestly.
                if let saving = models.plan.saving?.text(currency: entry.currency, nowMs: minute, zone: moment.timeZone) {
                    Text(saving).foregroundStyle(Theme.ink2)
                }
                if style == .dial {
                    Text(plannedLine(moment, zone: moment.timeZone))
                        .foregroundStyle(moment.state == .boxStale ? Theme.alarm : Theme.ink3)
                }
                // What the plan rests on: the prices are known, the sun and
                // the home's use are a forecast, and a style other than
                // balanced leans on it less or more.
                if let lean = styleLine {
                    Text(lean).foregroundStyle(Theme.ink3)
                }
            }
            .font(Theme.mono())
            .tracking(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        PriceRow(prices: prices, minute: minute)
        Levers(mode: models.mode, loadpoints: loadpoints, minute: minute, choose: chooseMode, reveal: reveal)
            .id(Self.leversID)
    }

    /// The price now in whole units, for the strip's header.
    private func priceNow(_ window: Prices?, _ minute: Double) -> String? {
        guard let window else { return nil }
        let current = window.slots.first { minute >= $0.startMs && minute < $0.startMs + $0.durationMs }
        return current.map { PriceStrip.whole($0.totalMinor, window.currency) }
    }

    /// "PLANNED 16:51 · REPLANS EVERY 15 MIN", or that the box could not.
    private func plannedLine(_ m: PlanGlance.Moment, zone: TimeZone) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs ?? m.readAtMs else { return L("Reading the plan from your box…") }
        return PlanDial.planned(atMs: at, old: m.state == .old, zone: zone)
    }

    /// "CAREFUL WITH THE FORECAST", when the planning style is not
    /// balanced. Nothing when it is, or before the box has said.
    private var styleLine: String? {
        guard let style = models.mode.shownStyle, style.key != "balanced" else { return nil }
        return NodeWords.format("%@ with the forecast", NodeWords.text(style.name)).uppercased()
    }

    /// When the box made it, or that it could not.
    private func stateLine(_ m: PlanGlance.Moment) -> String {
        if m.state == .boxStale { return L("Your box couldn't plan ahead just now, so it runs on safe defaults.") }
        guard let at = models.plan.receivedAtMs ?? m.readAtMs else { return L("Reading the plan from your box…") }
        return NodeWords.format("Planned by your box at %@. It plans again every quarter of an hour.", AppWords.clock(at, zone: m.timeZone))
    }
}

/// The dial and the half days it reaches, worked out once per plan, minute
/// and face, so a body that runs again for any other reason reads them.
@MainActor
private final class DialMemo {
    private var key: (entry: PlanEntry, minute: Double, page: Int)?
    private var kept: PlanDial?
    private var facesKey: (entry: PlanEntry, minute: Double)?
    private var keptFaces: [Double] = []

    func dial(_ entry: PlanEntry, nowMs: Double, page: Int) -> PlanDial {
        if let key, key.entry == entry, key.minute == nowMs, key.page == page, let kept { return kept }
        let d = PlanDial(plan: entry, prices: nil, nowMs: nowMs, page: page)
        key = (entry, nowMs, page)
        kept = d
        return d
    }

    /// Where each half day the plan reaches starts, and where the last ends.
    func faces(_ entry: PlanEntry, nowMs: Double) -> [Double] {
        if let facesKey, facesKey.entry == entry, facesKey.minute == nowMs { return keptFaces }
        keptFaces = PlanDial.pages(plan: entry, prices: nil, nowMs: nowMs)
        facesKey = (entry, nowMs)
        return keptFaces
    }
}

/// Which half day the dial shows, as dots under it: one for each the plan
/// reaches, the shown one in ink. A tap on a dot turns to it; VoiceOver
/// steps through them. Nothing shows while there is only now's.
private struct FaceDots: View {
    let count: Int
    @Binding var face: Int
    /// "TOMORROW 00–12", what the shown face is.
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { k in
                Button {
                    withAnimation(Theme.spring) { face = k }
                } label: {
                    Circle()
                        .fill(k == min(face, count - 1) ? Theme.ink : Theme.ink3)
                        .frame(width: 6, height: 6)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(count > 1 ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Half day"))
        .accessibilityValue(name)
        .accessibilityHidden(count < 2)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: face = min(face + 1, count - 1)
            case .decrement: face = max(face - 1, 0)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("plan.dial.faces")
    }
}

/// The strip worked out once per plan, minute and length, like the dial.
@MainActor
private final class StripMemo {
    private var key: (entry: PlanEntry, moment: PlanGlance.Moment, hasCar: Bool, quarters: Int, prices: [PriceSlot]?)?
    private var kept: PlanStrip?

    func strip(_ entry: PlanEntry, moment: PlanGlance.Moment, hasCar: Bool, quarters: Int, prices: [PriceSlot]?) -> PlanStrip {
        if let key, key.entry == entry, key.moment == moment, key.hasCar == hasCar, key.quarters == quarters, key.prices == prices, let kept { return kept }
        let s = PlanStrip.build(entry, moment: moment, hasCar: hasCar, quarters: quarters, prices: prices)
        key = (entry, moment, hasCar, quarters, prices)
        kept = s
        return s
    }
}

/// What each colour means, in short words: the figures under the strip
/// say the rest. The dial's ticks are as long as the battery's power; its
/// dashed gold rim is the box's sun forecast (xorath, 3 Nov 2026, found
/// nothing that said so).
private struct Legend: View {
    var sun = false
    var level = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
        .font(.caption2)
        .foregroundStyle(Theme.fgDim)
    }

    @ViewBuilder private var items: some View {
        item(Theme.gives, L("discharging"))
        item(Theme.stores, L("charging"))
        item(Theme.car, L("Car"))
        if sun {
            HStack(spacing: 4) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1))
                    p.addLine(to: CGPoint(x: 14, y: 1))
                }
                .stroke(Theme.solar.opacity(Theme.planSun(contrast)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: 14, height: 2)
                Text(L("sun forecast")).lineLimit(1)
            }
        }
        if level {
            HStack(spacing: 4) {
                Capsule().fill(Theme.ink2).frame(width: 12, height: 1.75)
                Text(L("battery level")).lineLimit(1)
            }
        }
    }

    private func item(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(Theme.plan(contrast))).frame(width: 10, height: 6)
            Text(text).lineLimit(1)
        }
    }
}

/// The price the plan stands on, in one row, and the way to its chart.
private struct PriceRow: View {
    let prices: PriceModel
    let minute: Double

    var body: some View {
        if let window = prices.prices {
            let current = window.slots.first { minute >= $0.startMs && minute < $0.startMs + $0.durationMs }
            NavigationLink(value: HomeRoute.price(nil)) {
                HStack(alignment: .firstTextBaseline) {
                    Kicker(L("Electricity price"))
                    Spacer(minLength: 8)
                    if let current {
                        Text("\(Text(AppWords.decimal(PriceStrip.text(current.totalMinor, window.currency))).font(Theme.figure(15)).foregroundStyle(Theme.fg)) \(Text(PriceUnits.unit(window.currency).perKwh).font(.caption2).foregroundStyle(Theme.fgMuted))")
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.fgMuted)
                }
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan.price")
        }
    }
}

/// "New plan 16:53: stores 22:45 instead of 03:45.", after a change of the
/// person's own, until the next plan.
private struct MovedLine: View {
    let text: String?

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityIdentifier("plan.moved")
            }
        }
        .animation(.easeOut(duration: 0.2), value: text)
    }
}

/// What the person can change, at the foot of the plan: the car's goal,
/// the mode, and while the plan runs its style as a scale with five stops.
private struct Levers: View {
    let mode: ModeModel
    let loadpoints: LoadpointsModel
    let minute: Double
    let choose: () -> Void
    let reveal: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lp = loadpoints.points.first {
                NavigationLink(value: HomeRoute.car(lp.id)) {
                    row(L("Car"), value: goal(lp), tint: Theme.ink, symbol: "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("plan.car")
                Divider().overlay(Theme.hairline)
            }
            if let label {
                // The one place the mode changes. While a change is on its
                // way the row says what the box answered, a refusal's reason
                // too; a phone that may not change the mode reads a plain row.
                let value = mode.outcome?.text ?? label
                if mode.mayControl {
                    Button(action: choose) {
                        row(L("Mode"), value: value, tint: Theme.accent, symbol: "chevron.up.chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(!mode.canControl)
                    .accessibilityHint(L("Change mode"))
                    .accessibilityIdentifier("plan.mode")
                    .animation(Theme.spring, value: mode.outcome)
                } else {
                    row(L("Mode"), value: value, tint: Theme.ink, symbol: nil)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("plan.mode")
                }
            }
            if showsScale {
                #if DEBUG
                StyleScale(mode: mode, id: "plan.style.scale", drives: true, reveal: reveal)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                #else
                StyleScale(mode: mode, id: "plan.style.scale")
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                #endif
            }
        }
    }

    /// The scale stands in for the style while the plan runs and this
    /// phone may change it; else the row names it.
    private var showsScale: Bool { mode.mayControl && mode.shownStyle != nil && ModeWords.isPlan(mode.shown ?? "") }

    /// "Plan" when the scale below says the style, else "Plan · Balanced"
    /// or a manual mode's name.
    private var label: String? {
        guard let key = mode.shown else { return mode.label }
        return showsScale && ModeWords.isPlan(key) ? L("Plan") : mode.label
    }

    /// "80 % by 07:00 on weekdays", the goal the plan charges for.
    private func goal(_ lp: Loadpoint) -> String {
        guard let s = lp.schedule else { return L("No goal") }
        return EVText.goal(s, at: Date(timeIntervalSince1970: minute / 1000), zone: loadpoints.zone)
    }

    private func row(_ kicker: String, value: String, tint: Color, symbol: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Kicker(kicker)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint == Theme.ink ? Theme.ink3 : tint)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private extension String {
    /// "Power is cheap · up to 3 kW": a sentence starts with a capital.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
