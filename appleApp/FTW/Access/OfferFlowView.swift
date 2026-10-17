import FTWKit
import SwiftUI

/// An assistant's offer, from its consent page to Face ID. A link or the
/// page's QR code opens it at once; with neither, the owner types the code
/// first. Then who is asking, the host before the name it gives itself,
/// what it may read, control as its own switch, off, and for how long.
/// The steps of one offer, pushed over the home for a link or from Access
/// for a typed code. A page, never a sheet: FTW Cloud's first screen or
/// Settings may be up when a link arrives, and a page waits under them.
struct OfferFlowView: View {
    let app: AppModel
    @State var flow: OfferFlow
    @Environment(\.dismiss) private var dismiss
    @FocusState private var codeFocused: Bool

    private var access: AccessModel? { app.home?.access }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationBarTitleDisplayMode(.inline)
            .task { await flow.start(home: app.cloudHome) }
            .sensoryFeedback(trigger: flow.step) { _, step in
                switch step {
                case .done: return .success
                case .refused: return .error
                default: return nil
                }
            }
            .animation(Theme.spring, value: flow.step)
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .code:
            codeStep
        case .checking:
            VStack(spacing: 12) {
                ProgressView()
                Text(AccessWords.text("Checking the offer")).foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review(let offer), .approving(let offer):
            if let access {
                OfferReview(app: app, access: access, flow: flow, offer: offer)
            }
        case .done(let row):
            Outcome(icon: "checkmark.seal.fill", tint: Theme.ink, title: AccessWords.format("%@ can now reach your home.", AccessWords.name(row)),
                    text: AccessWords.text("Your box checks every call, and you can remove the access at any time.")) { dismiss() }
        case .refused(let e):
            Outcome(icon: "xmark.octagon.fill", tint: Theme.alarm, title: AccessWords.offer(e), text: nil) { dismiss() }
        }
    }

    private var codeStep: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AccessWords.text("Type the code on the page")).font(.title2.weight(.bold))
                    Text(AccessWords.text("The page that asked for access shows a code. Type it here only if you started this yourself, on a page you trust."))
                        .foregroundStyle(Theme.ink2)
                }
                .padding(.vertical, 4)
            }
            Section {
                TextField("ABCD-EFGH", text: $flow.typed)
                    .font(.title2.monospaced().weight(.semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .submitLabel(.continue)
                    .focused($codeFocused)
                    .onSubmit { Task { await flow.submit(home: app.cloudHome) } }
                    .accessibilityIdentifier("offer.code")
            } footer: {
                if let help = flow.codeHelp { Text(help).foregroundStyle(Theme.alarm) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(AccessWords.text("Continue")) { Task { await flow.submit(home: app.cloudHome) } }
                .buttonStyle(FTWButtonStyle(kind: .primary))
                .disabled(OfferCode.normalize(flow.typed) == nil)
                .padding(16)
                .accessibilityIdentifier("offer.continue")
        }
        .onAppear { codeFocused = true }
    }
}

/// The offer, verified, for the owner to choose from.
struct OfferReview: View {
    let app: AppModel
    let access: AccessModel
    @Bindable var flow: OfferFlow
    let offer: GrantOffer

    var body: some View {
        let grant = flow.grant(offer)
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(offer.clientHost)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("offer.host")
                    Label(AccessWords.text(offer.verified ? "Verified by FTW Cloud" : "Not verified"),
                          systemImage: offer.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(offer.verified ? Theme.ink : Theme.alarm)
                    if offer.isSupport {
                        Text(AccessWords.text("Sourceful support")).foregroundStyle(Theme.ink2)
                    } else if AccessWords.nameHidden(offer.client) {
                        Text(AccessWords.text("The name it gives mentions Sourceful or FTW, so it is not shown."))
                            .font(.subheadline)
                            .foregroundStyle(Theme.alarm)
                    } else if let name = AccessWords.ownName(offer.client) {
                        Text(AccessWords.format("Calls itself %@", name)).foregroundStyle(Theme.ink2)
                    }
                    if offer.isSupport, !offer.ticket.isEmpty {
                        Text(AccessWords.format("Ticket %@", offer.ticket)).font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                }
                .padding(.vertical, 4)
                if let code = flow.pageCode {
                    LabeledContent(AccessWords.text("Code on the page")) {
                        Text(code).font(Theme.mono(.body, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    .accessibilityIdentifier("offer.pageCode")
                }
            } footer: {
                if !offer.verified {
                    Text(AccessWords.text("FTW Cloud doesn't know this client. Check that the address is the one you expect."))
                }
            }

            if !offer.verified {
                Section {
                    Toggle(AccessWords.format("I started this myself and trust %@.", offer.clientHost), isOn: $flow.trustsUnknown)
                        .tint(Theme.alarm)
                        .accessibilityIdentifier("offer.trust")
                }
            }

            Section(AccessWords.text("It may")) {
                ForEach(AccessWords.ordered(grant.scopes.filter { !AccessWire.controlScopes.contains($0) }), id: \.self) { scope in
                    Label(AccessWords.scope(scope), systemImage: "eye")
                }
            }

            if offer.asksControl {
                Section {
                    Toggle(AccessWords.text("Also let it control"), isOn: $flow.control)
                        .tint(Theme.live)
                        .accessibilityIdentifier("offer.control")
                } footer: {
                    let asked = Grant.from(offer, control: true, lengthMs: flow.lengthMs)
                    Text(flow.control ? AccessWords.control(asked.caps, scopes: asked.scopes) : AccessWords.text("Off: it reads and changes nothing."))
                }
                if flow.control {
                    Section(AccessWords.text("With control it may")) {
                        ForEach(Grant.from(offer, control: true, lengthMs: flow.lengthMs).ops, id: \.self) { op in
                            Label(AccessWords.op(op), systemImage: Contract.agentOps[op] == AccessWire.scopeHold ? "bolt" : "hand.raised")
                        }
                    }
                }
            }


            Section {
                Picker(AccessWords.text("For"), selection: $flow.lengthMs) {
                    ForEach(flow.lengths, id: \.self) { Text(AccessWords.length($0)).tag($0) }
                }
                .accessibilityIdentifier("offer.length")
                HomePick(app: app, flow: flow, offer: offer)
            } footer: {
                if let help = access.help { Text(help).foregroundStyle(Theme.alarm) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await flow.approve(access, home: app.cloudHome) } } label: {
                HStack(spacing: 8) {
                    if case .approving = flow.step { ProgressView().tint(Theme.onAccent) } else { Image(systemName: Biometry.symbol) }
                    Text(AccessWords.format("Approve with %@", AccessWords.biometry))
                }
            }
            .buttonStyle(FTWButtonStyle(kind: .primary))
            .disabled(!access.available || flow.offer == nil || !(offer.verified || flow.trustsUnknown)
                || { if case .approving = flow.step { return true }; return false }())
            .padding(16)
            .background(Theme.surface)
            .accessibilityIdentifier("offer.approve")
        }
    }
}

/// The home the grant is for. With several, the owner picks one: that
/// home opens and the link starts again there, so nothing checked at one
/// home is taken to another. An offer that names its home, or one found by
/// a code, which FTW Cloud gives once, stays where it is.
struct HomePick: View {
    let app: AppModel
    let flow: OfferFlow
    let offer: GrantOffer

    var body: some View {
        if app.homes.count > 1, offer.home.isEmpty, let link = flow.link, let current = app.site?.siteId {
            Picker(AccessWords.text("Home"), selection: Binding(get: { current }, set: { home in
                guard home != current else { return }
                app.open(home)
                app.accessLink = link
            })) {
                ForEach(app.homes) { Text(HomeName.title($0.label)).tag($0.siteId) }
            }
        } else {
            LabeledContent(AccessWords.text("Home"), value: app.homeName)
        }
    }
}

/// How a sheet ended, with the one way out.
struct Outcome: View {
    let icon: String
    let tint: Color
    let title: String
    let text: String?
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: title)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if let text { Text(text).foregroundStyle(Theme.ink2).multilineTextAlignment(.center) }
            Spacer()
            Button(AccessWords.text("Done"), action: done)
                .buttonStyle(FTWButtonStyle(kind: .primary))
                .accessibilityIdentifier("offer.done")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
