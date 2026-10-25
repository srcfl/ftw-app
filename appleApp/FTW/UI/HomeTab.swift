import FTWKit
import SwiftUI

/// Home, the fourth tab: the home itself, in the system's own list. Its
/// cars, its assistants and the watch; then the homes on this
/// phone, this phone's own settings, and what FTW is. What the title's
/// menu and the settings sheet held before the tabs, in one place a
/// newcomer finds.
struct HomeTabView: View {
    let app: AppModel
    let home: HomeModels
    @Binding var sheet: HomeSheet?
    /// Back to the tab's root, after this phone is removed.
    let popToRoot: () -> Void

    var body: some View {
        List {
            thisHome
            if let access = home.access {
                AccessSettingsSection(app: app, access: access)
            }
            if app.watch.canAdd(home) {
                WatchSettingsSection(app: app, home: home)
            }
            homes
            phone
            about
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
    }

    /// The home's name over its cars. How it is run is changed in Plan, the
    /// one place for the mode and the planning style.
    @ViewBuilder private var thisHome: some View {
        if home.cars.keepsCars {
            Section {
                NavigationLink { CarsSettingsView(cars: home.cars) } label: {
                    LabeledContent {
                        Text(home.cars.cars.map(\.shownName).joined(separator: ", "))
                            .lineLimit(1)
                    } label: {
                        Label(C("Cars"), systemImage: "car.side")
                    }
                }
                .accessibilityIdentifier("settings.cars")
            } header: {
                Text(app.homeName)
            }
        }
    }

    /// The homes this phone holds, the open one ticked, and the way to
    /// pair another.
    private var homes: some View {
        Section(L("Homes")) {
            ForEach(app.homes) { h in
                Button { app.open(h.siteId) } label: {
                    HStack {
                        Text(HomeName.title(h.label)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        if !app.isDemo, app.site?.siteId == h.siteId {
                            Image(systemName: "checkmark").foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            Button { app.recovering = true } label: {
                Label(L("Pair a home"), systemImage: "qrcode.viewfinder")
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    /// FTW Cloud and removing this phone, for a paired home. The demo has
    /// neither.
    @ViewBuilder private var phone: some View {
        if !app.isDemo {
            Section(AboutWords.text("This phone")) {
                NavigationLink { CloudSettingsView(app: app) } label: {
                    Label(CloudWords.text("FTW Cloud"), systemImage: "cloud")
                }
                if AboutView.canRemove(app) {
                    NavigationLink { RemovePhoneView(app: app, close: popToRoot) } label: {
                        Text(AboutWords.text("Remove this phone")).foregroundStyle(Theme.alarm)
                    }
                }
            }
        }
    }

    /// What FTW is and how it treats your data, the way out of the demo,
    /// and the build.
    private var about: some View {
        Section {
            Button { sheet = .about(.about) } label: {
                Label(L("About FTW"), systemImage: "info.circle").foregroundStyle(Theme.ink)
            }
            .accessibilityIdentifier("menu.about")
            Link(destination: Origin.privacyURL()) {
                Label(AboutWords.text("Privacy"), systemImage: "hand.raised").foregroundStyle(Theme.ink)
            }
            if app.isDemo {
                Button { app.exitDemo() } label: {
                    Label(L("Exit demo"), systemImage: "xmark.circle").foregroundStyle(Theme.ink)
                }
                .accessibilityIdentifier("demo.exit")
            }
        } footer: {
            Text(verbatim: "FTW \(BuildSource.bundled.versionText)")
        }
    }
}
