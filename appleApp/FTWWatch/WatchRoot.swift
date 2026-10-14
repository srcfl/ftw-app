import FTWShared
import SwiftUI

/// Four pages, one idea each: Now, the plan, the car and the price. The
/// Crown moves between them, except on the plan, where it steps the hand.
struct WatchRoot: View {
    let model: WatchModel
    @State private var page: Page = WatchRoot.firstPage

    enum Page: String, Hashable { case now, plan, car, price }

    var body: some View {
        NavigationStack {
            if model.hasHome {
                TabView(selection: $page) {
                    NowPage(model: model).tag(Page.now)
                    PlanPage(model: model).tag(Page.plan)
                    CarPage(model: model).tag(Page.car)
                    PricePage(model: model).tag(Page.price)
                }
                .tabViewStyle(.verticalPage)
            } else {
                NoHome(waiting: model.context == nil)
            }
        }
        .containerBackground(Theme.ground, for: .navigation)
    }

    /// `-FTWWatchPage plan` opens on a page, for screenshots.
    static var firstPage: Page {
        UserDefaults.standard.string(forKey: "FTWWatchPage").flatMap(Page.init(rawValue:)) ?? .now
    }
}

/// Before the phone has handed over a home, or after it signed out.
private struct NoHome: View {
    let waiting: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(WatchWord.openOnPhone.text)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(WatchWord.openOnPhoneDetail.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("FTW")
        .accessibilityIdentifier("watch.nohome")
    }
}

/// Now in one glance: each node's figure, lit in its hue while the phone
/// streams it, ink with the time it was read otherwise, and how the home
/// is run.
struct NowPage: View {
    let model: WatchModel
    /// Always On redraws once a minute: a figure lit then would show an old
    /// reading as live, so nothing glows while the wrist is down.
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        let lit = model.lit && !dim
        let figures = WatchGlance.figures(model.now?.value, lit: lit)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                StatusLine(status: WatchGlance.status(model.now, lit: lit, demo: model.context?.isDemo == true, zone: model.zone))
                    .padding(.bottom, 2)
                ForEach(figures) { f in
                    FigureRow(figure: f, way: model.now?.value.reading(f.node)?.way ?? .resting)
                }
                if let modes = model.context?.modes, let label = modes.label {
                    NavigationLink {
                        ModeList(model: model, modes: modes)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(WatchWord.mode.text.uppercased())
                                    .font(Theme.mono(.caption2))
                                    .foregroundStyle(Theme.ink3)
                                Text(label)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if model.sending(WatchModel.modeTarget) {
                                ProgressView().frame(width: 16)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .accessibilityIdentifier("watch.mode")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(WatchWord.nowTitle.text)
    }
}

/// One node: its name and word on the left, the figure on the right. Lit,
/// the figure takes its kind's hue; otherwise it is ink and holds still.
private struct FigureRow: View {
    let figure: WatchGlance.Figure
    let way: WatchNow.Way

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(figure.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                Text(figure.level.map { "\(figure.word) · \($0)" } ?? figure.word)
                    .font(.caption2)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(figure.value)
                    .font(Theme.figure(20))
                    .foregroundStyle(figure.lit ? Hue.of(figure.node, way: way) : Theme.ink)
                    .contentTransition(.numericText())
                Text(figure.unit)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.ink2)
            }
            .animation(Theme.spring, value: figure.value)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.now.\(figure.node.rawValue)")
    }
}

/// The box's modes, as the phone last read them. A choice asks once more
/// and then goes through the phone; the receipt stays under the list.
struct ModeList: View {
    let model: WatchModel
    let modes: WatchModes
    @State private var asking: WatchModes.Mode?

    var body: some View {
        List {
            Section {
                ForEach(modes.modes) { m in
                    Button {
                        asking = m
                    } label: {
                        HStack {
                            Text(m.name).foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                            if m.key == modes.shown {
                                Image(systemName: "checkmark").foregroundStyle(Theme.ink2)
                            }
                        }
                    }
                    .disabled(!modes.mayControl || !model.canSend || model.sending(WatchModel.modeTarget) || m.key == modes.shown)
                    .accessibilityIdentifier("watch.mode.\(m.key)")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.canSend {
                        Text(WatchWord.phoneUnreachable.text).foregroundStyle(Theme.ink2)
                    } else if !modes.mayControl {
                        Text(WatchWord.cannotChangeMode.text).foregroundStyle(Theme.ink2)
                    }
                    if let r = model.receipt(for: WatchModel.modeTarget) {
                        ReceiptLine(receipt: r)
                    }
                }
                .font(.footnote)
            }
        }
        .navigationTitle(WatchWord.mode.text)
        .sheet(item: $asking) { m in
            Confirm(question: WatchWord.modeAsk.format(m.name), action: m.name) {
                model.send(.mode(m.key))
            }
        }
    }
}

/// One more question before a command, with the double tap on the yes.
struct Confirm: View {
    let question: String
    let action: String
    let go: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(question)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action) {
                    go()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ink)
                .foregroundStyle(Theme.ground)
                .handGestureShortcut(.primaryAction)
                .accessibilityIdentifier("watch.confirm")
                Button(WatchWord.cancel.text, role: .cancel) { dismiss() }
            }
        }
    }
}
