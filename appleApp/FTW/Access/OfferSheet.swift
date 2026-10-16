import FTWKit
import SwiftUI

/// An assistant's offer, from its consent page to Face ID. The code the
/// page shows first, so a link someone else sent stops here; then who is
/// asking, the host before the name it gives itself, what it may read,
/// control as its own switch, off, and for how long.
struct OfferSheet: View {
    let app: AppModel
    let flow: OfferFlow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OfferFlowView(app: app, flow: flow)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier("offer.close")
                    }
                }
        }
    }
}

/// The steps of one offer, in a sheet for a link or pushed from Access
/// for a typed code.
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
                    Text(AccessWords.text("The page that asked for access shows a code. Typing it here proves the request is the one in front of you."))
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
                    Text(offer.clientHost.isEmpty ? offer.clientId : offer.clientHost)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("offer.host")
                    Label(AccessWords.text(offer.verified ? "Verified by FTW Cloud" : "Not verified"),
                          systemImage: offer.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(offer.verified ? Theme.ink : Theme.alarm)
                    Text(AccessWords.format("Calls itself %@", "“\(AccessWords.clientName(offer))”"))
                        .foregroundStyle(Theme.ink2)
                    if offer.isSupport, !offer.ticket.isEmpty {
                        Text(AccessWords.format("Ticket %@", offer.ticket)).font(.subheadline).foregroundStyle(Theme.ink2)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                if !offer.verified {
                    Text(AccessWords.text("FTW Cloud doesn't know this client. Check that the address is the one you expect."))
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
            }

            Section {
                Picker(AccessWords.text("For"), selection: $flow.lengthMs) {
                    ForEach(flow.lengths, id: \.self) { Text(AccessWords.length($0)).tag($0) }
                }
                .accessibilityIdentifier("offer.length")
                HomePick(app: app)
            } footer: {
                if let help = access.help { Text(help).foregroundStyle(Theme.alarm) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await flow.approve(access) } } label: {
                HStack(spacing: 8) {
                    if case .approving = flow.step { ProgressView().tint(Theme.onAccent) } else { Image(systemName: Biometry.symbol) }
                    Text(AccessWords.format("Approve with %@", AccessWords.biometry))
                }
            }
            .buttonStyle(FTWButtonStyle(kind: .primary))
            .disabled(!access.available || flow.offer == nil || { if case .approving = flow.step { return true }; return false }())
            .padding(16)
            .background(Theme.surface)
            .accessibilityIdentifier("offer.approve")
        }
    }
}

/// The home the grant is for. With several, the owner picks one, which
/// opens it.
struct HomePick: View {
    let app: AppModel

    var body: some View {
        if app.homes.count > 1, let current = app.site?.siteId {
            Picker(AccessWords.text("Home"), selection: Binding(get: { current }, set: { app.open($0) })) {
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
