import FTWKit
import SwiftUI
import UserNotifications

/// Home › Notifications: whether this iPhone lets FTW notify, then the box's
/// own choices, the same ones the web app and the box's settings show. The
/// box decides when to send; these say which kinds it sends at all.
struct NotifySettingsView: View {
    let home: HomeModels
    @State private var allowed: UNAuthorizationStatus?
    @Environment(\.scenePhase) private var scenePhase

    private var rules: NotifyRules { home.notify }

    var body: some View {
        List {
            phone
            box
            if rules.phase == .ready, rules.canChange {
                ForEach(NotifyRules.Group.allCases, id: \.self) { group in
                    let kinds = rules.kinds.filter { NotifyRules.group($0) == group }
                    if !kinds.isEmpty {
                        Section(Self.title(group)) {
                            ForEach(kinds, id: \.self) { kind in
                                Toggle(NotifyRules.label(kind), isOn: Binding(
                                    get: { rules.on[kind] == true },
                                    set: { value in Task { await rules.set(kind, value) } }
                                ))
                                .accessibilityIdentifier("notify.\(kind)")
                            }
                        }
                        .disabled(!rules.boxOn)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .navigationTitle(L("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .animation(Theme.spring, value: rules.kinds)
        // Read when the view opens and when the session comes back.
        .task(id: home.site.session.phase == .streaming) { await rules.load() }
        // Back from the iPhone's Settings, the answer may have changed.
        .task(id: scenePhase) { allowed = await Notifications.allowed() }
    }

    /// This iPhone's own answer: asked here if never asked, or the way to
    /// Settings if refused.
    @ViewBuilder private var phone: some View {
        switch allowed {
        case .notDetermined?:
            Section {
                Button {
                    Task {
                        await Notifications.askAndRegister()
                        allowed = await Notifications.allowed()
                    }
                } label: {
                    Label(L("Allow notifications on this iPhone"), systemImage: "bell.badge")
                }
                .accessibilityIdentifier("notify.allow")
            }
        case .denied?:
            Section {
                Text(L("Notifications for FTW are off in the iPhone's Settings."))
                if let url = Notifications.settingsURL {
                    Link(L("Open Settings"), destination: url)
                }
            }
        default:
            EmptyView()
        }
    }

    /// The box's own switch, or why there is none to show.
    @ViewBuilder private var box: some View {
        Section {
            if !home.site.canConfigure {
                Text(L("Notifications are chosen by this home's owner.")).foregroundStyle(Theme.ink2)
            } else if rules.phase == .oldBox {
                Text(AppWords.text("Your box doesn't have that yet — it may be running older software.")).foregroundStyle(Theme.ink2)
            } else if rules.phase == .unknown {
                Text(L(home.site.session.phase == .streaming ? "Reading your box…" : "Shown when your box is in reach."))
                    .foregroundStyle(Theme.ink2)
            } else {
                Toggle(L("Notifications from your box"), isOn: Binding(
                    get: { rules.boxOn },
                    set: { value in Task { await rules.setBoxOn(value) } }
                ))
                .accessibilityIdentifier("notify.box")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if rules.phase == .ready {
                    Text(L("Your box decides when to send them, and every owner of this home gets the same. Notices about access come even with this off."))
                }
                if let problem = rules.problem {
                    Text(problem).foregroundStyle(Theme.alarm)
                }
            }
        }
    }

    static func title(_ group: NotifyRules.Group) -> String {
        switch group {
        case .car: return L("The car")
        case .home: return L("The box and its devices")
        case .access: return L("Access")
        }
    }
}
