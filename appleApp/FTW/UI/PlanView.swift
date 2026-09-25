import FTWKit
import SwiftUI

/// What the box means to do, how the home is run, and what power costs.
struct PlanView: View {
    let home: HomeModels
    @State private var showAdvanced = false

    private var plan: PlanModel { home.plan }
    private var site: SiteModel { home.site }

    var body: some View {
        Group {
            Text(PlanText.headline(plan.plan, nowMs: site.nowMs).text)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let problem = plan.problem { Problem(problem) }

            modes

            if let prices = home.prices.prices {
                Card {
                    PriceChart(prices: prices, nowMs: site.nowMs)
                    if home.prices.hasHole {
                        Hint("Some hours are missing their price.")
                    } else if prices.stale {
                        Hint("Tomorrow's rates aren't published yet.")
                    }
                }
            }

            timeline
        }
        .onAppear {
            plan.activate()
            home.prices.activate()
        }
        .onDisappear {
            plan.deactivate()
            home.prices.deactivate()
        }
    }

    // MARK: How the home is run

    @ViewBuilder private var modes: some View {
        Kicker("How your home is run")
        if plan.inManual, let planHome = plan.planHome {
            Card {
                Text("The plan is not running the battery.")
                if plan.canControl {
                    Button(sendingMode == planHome.key ? "Sending…" : "Use the plan") { choose(planHome.key) }
                        .buttonStyle(.primary)
                        .disabled(isSending)
                }
            }
        }
        ForEach(plan.primaryModes) { choice($0) }
        if !plan.advancedModes.isEmpty {
            if showAdvanced {
                ForEach(plan.advancedModes) { choice($0) }
                Button("Fewer options") { showAdvanced = false }.buttonStyle(.quiet)
            } else {
                if let selected = plan.advancedModes.first(where: { $0.key == plan.shownMode }) {
                    choice(selected)
                }
                Button("More ways to run it") { showAdvanced = true }.buttonStyle(.quiet)
            }
        }
        status
    }

    private var isSending: Bool {
        if case .sending = plan.command { return true }
        return false
    }

    private var sendingMode: String? {
        if case .sending(let m) = plan.command { return m }
        return nil
    }

    private func choose(_ mode: String) {
        Task { await plan.setMode(mode) }
        if plan.advancedModes.contains(where: { $0.key == mode }) { showAdvanced = false }
    }

    private func choice(_ info: ModeInfo) -> some View {
        let pressed = plan.shownMode == info.key
        return Button { choose(info.key) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(PlanText.label(info)).font(.body.weight(.semibold)).foregroundStyle(Theme.fg)
                    Spacer()
                    if sendingMode == info.key {
                        Text("Sending…").font(.caption).foregroundStyle(Theme.fgDim)
                    } else if pressed {
                        Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                }
                Text(PlanText.help(info))
                    .font(.footnote)
                    .foregroundStyle(Theme.fgDim)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(pressed ? Theme.accent : Theme.line, lineWidth: pressed ? 2 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!plan.canControl || isSending)
        .accessibilityAddTraits(pressed ? .isSelected : [])
    }

    /// One line, in the band's voice. Never a modal.
    @ViewBuilder private var status: some View {
        switch plan.command {
        case .sending:
            Hint("Sending…")
        case .applied:
            Hint("Done.", tone: Theme.exporting)
        case .unconfirmed:
            Hint("Your box took it, but hasn't confirmed yet. It'll show here when it does.", tone: Theme.generation)
        case .failed(let help):
            Hint(help, tone: Theme.generation)
        case .idle:
            switch plan.whyNoControl {
            case .role: Hint("You have view-only access, so this is the owner's to change.")
            case .box: Hint("This box doesn't support changing how it runs.")
            case nil: EmptyView()
            }
        }
    }

    // MARK: The next twelve hours

    @ViewBuilder private var timeline: some View {
        let now = site.nowMs
        let slots = Array((plan.plan?.slots ?? []).filter { $0.startMs + $0.durationMs > now }.prefix(48))
        if !slots.isEmpty {
            let peak = max(1, slots.map { abs($0.batteryW) }.max() ?? 1)
            let currency = home.prices.currency
            HStack {
                Kicker("Next 12 hours")
                Spacer()
                Text("to import, \(PriceUnits.unit(currency).perKwh)").font(.caption).foregroundStyle(Theme.fgMuted)
            }
            VStack(spacing: 0) {
                ForEach(slots) { slot in
                    SlotRow(slot: slot, peakW: peak, isNow: now >= slot.startMs && now < slot.startMs + slot.durationMs, currency: currency)
                }
            }
        } else if plan.loading {
            Hint("Asking your box…")
        }
    }
}

private struct SlotRow: View {
    let slot: PlanSlot
    let peakW: Double
    let isNow: Bool
    let currency: String

    var body: some View {
        let action = PlanText.action(slot)
        let parts = PowerFormat.parts(slot.batteryW)
        HStack(spacing: 10) {
            Text(Clock.time(slot.startMs))
                .font(Theme.number(13, weight: isNow ? .bold : .regular))
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(action == .charge ? Theme.storage : action == .discharge ? Theme.accent : Theme.fgMuted)
                    .frame(width: max(2, geo.size.width * abs(slot.batteryW) / peakW))
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 60, height: 6)
            Group {
                if action == .idle {
                    Text("resting").foregroundStyle(Theme.fgDim)
                } else {
                    Text(parts.text).font(Theme.number(13)) + Text(" \(parts.unit) \(action == .charge ? "in" : "out")").foregroundStyle(Theme.fgDim)
                }
            }
            .font(.footnote)
            .frame(width: 90, alignment: .leading)
            Text(PlanText.reason(slot.reason))
                .font(.footnote)
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let price = PriceUnits.text(slot.priceMinor, currency) {
                Text(price).font(Theme.number(12, weight: .regular)).foregroundStyle(Theme.fgDim)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(isNow ? Theme.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
