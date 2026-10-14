import FTWShared
import SwiftUI

/// Four pages, one idea each, each on one screen with nothing to scroll:
/// Now alive, the plan, the car and the price. The Crown turns the pages,
/// except on the plan, where it steps the hand; a swipe goes on from there.
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
