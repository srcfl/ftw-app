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
    @AppStorage(Appearance.key) private var appearance = Appearance.standard
    @AppStorage(PriceShown.feesKey) private var fees = true
    @AppStorage(PriceShown.vatKey) private var vat = true

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
            price
            look
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

    /// Which price the app shows, on this phone: the total the household
    /// pays, or the spot price without the grid fee and tax, each with or
    /// without VAT. The footer names what is shown, so a price is never
    /// read under the wrong name.
    private var price: some View {
        // Before the box's prices are read, the label names the choice;
        // once they are, it names what they allow.
        let held = home.prices.prices
        let unsaid = held != nil && held?.vatPermille == nil
        let kind = PriceShown(fees: fees, vat: vat).kind(vatPermille: unsaid ? nil : held?.vatPermille ?? 0)
        return Section {
            Toggle(L("With grid fee and tax"), isOn: $fees)
                .accessibilityIdentifier("settings.price.fees")
            Toggle(L("With VAT"), isOn: $vat)
                .accessibilityIdentifier("settings.price.vat")
        } header: {
            Text(L("Price shown"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(PriceShown.label(kind)).font(Theme.mono()).tracking(0.5)
                if unsaid, kind != PriceShown(fees: fees, vat: vat).kind(vatPermille: 250) {
                    Text(L("Your box does not say its VAT rate yet, so FTW shows the price it has and says which."))
                }
                Text(L("Now, the plan and the price on this phone. The widgets and the watch show the total with VAT."))
            }
        }
    }

    /// Dark, light or the iPhone's own setting, for this app on this phone.
    private var look: some View {
        Section {
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            } label: {
                Label(L("Appearance"), systemImage: "circle.lefthalf.filled")
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityIdentifier("settings.appearance")
        } footer: {
            Text(L("Widgets and the watch follow the iPhone."))
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
