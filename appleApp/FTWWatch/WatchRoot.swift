import FTWShared
import SwiftUI

/// Four pages, one idea each, each on one screen with nothing to scroll:
/// Now alive, the plan, the car and the price. The Crown turns the pages,
/// except on the plan, where it steps the hand; a swipe goes on from there.
/// Each page takes the space rule (`pageSpace`): no title, and the screen
/// down to its corner.
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

    /// What a page leaves free at the screen's foot for its rounded corner.
    static let cornerRoom: CGFloat = 8
}

extension View {
    /// The space rule for every page. No navigation title: the clock stays
    /// and the content starts under it. The content runs into the bottom
    /// safe area and stops `WatchRoot.cornerRoom` short of the edge, as the
    /// system's own apps do. Now has it; Plan, Car and Price take it next.
    func pageSpace() -> some View {
        padding(.bottom, WatchRoot.cornerRoom)
            .ignoresSafeArea(.container, edges: .bottom)
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
