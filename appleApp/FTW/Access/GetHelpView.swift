import FTWKit
import SwiftUI

/// Get help: the owner says what is wrong and lets Sourceful look at the
/// home for one ticket. Reading and checks that change nothing; control
/// only when ticked. One Face ID grants it, tied to the ticket, and it ends
/// when the ticket closes, when its time runs out or when the owner
/// removes it.
///
/// There is no help desk behind the app yet. A release build says so and
/// offers nothing to press; the simulated home has a desk of its own.
struct GetHelpView: View {
    let app: AppModel
    let access: AccessModel
    @State private var problem = ""
    @State private var control = false
    @State private var asking = false
    @State private var ticket: String?
    @State private var help: String?
    @FocusState private var writing: Bool

    private static let weekMs: Int64 = 7 * 86_400_000
    private static let reads = ["ftw.live.read", "ftw.history.read", "ftw.plan.read", "ftw.health.read", "ftw.events.read", "ftw.logs.read", "ftw.config.read", "ftw.diag.run"]

    var body: some View {
        Group {
            if let ticket {
                Outcome(icon: "checkmark.seal.fill", tint: Theme.ink, title: AccessWords.format("Sourceful can now look at your home for ticket %@.", ticket),
                        text: AccessWords.text("Every call names the person at Sourceful who made it. You can remove the access at any time, and it ends when the ticket closes.")) {
                    self.ticket = nil
                    problem = ""
                }
            } else {
                form
            }
        }
        .navigationTitle(AccessWords.text("Get help"))
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.surface)
        .sensoryFeedback(.success, trigger: ticket)
    }

    private var form: some View {
        let desk = app.desk
        return List {
            Section(AccessWords.text("Describe the problem")) {
                TextField(AccessWords.text("What happened, and when?"), text: $problem, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($writing)
                    .accessibilityIdentifier("help.problem")
            }
            Section {
                ForEach(Self.reads, id: \.self) { Label(AccessWords.scope($0), systemImage: "eye") }
                Toggle(AccessWords.text("Also let Sourceful control"), isOn: $control)
                    .tint(Theme.live)
                    .accessibilityIdentifier("help.control")
                LabeledContent(AccessWords.text("For"), value: AccessWords.length(Self.weekMs))
            } header: {
                Text(AccessWords.text("Sourceful may"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if control {
                        Text(AccessWords.control(Caps(holdS: AccessWire.holdSRange.upperBound, maxW: 11_000), scopes: Array(AccessWire.controlScopes)))
                    }
                    Text(AccessWords.text("Every call names the person at Sourceful who made it. You can remove the access at any time, and it ends when the ticket closes."))
                    if !desk.isOpen { Text(AccessWords.text("Sourceful can't open a ticket from the app yet.")).foregroundStyle(Theme.alarm) }
                    if let help = help ?? access.help { Text(help).foregroundStyle(Theme.alarm) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AccessWords.text("Done")) { writing = false }
                    .accessibilityIdentifier("help.written")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await look(desk) } } label: {
                HStack(spacing: 8) {
                    if asking { ProgressView().tint(Theme.onAccent) } else { Image(systemName: Biometry.symbol) }
                    Text(AccessWords.text("Let Sourceful look"))
                }
            }
            .buttonStyle(FTWButtonStyle(kind: .primary))
            .disabled(!desk.isOpen || asking || problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !access.available)
            .padding(16)
            .background(Theme.surface)
            .accessibilityIdentifier("help.look")
        }
    }

    /// The desk opens the ticket and hands back Sourceful's signed offer,
    /// which is checked like any other; the owner's choice of control and
    /// the week go into the grant, behind one Face ID.
    private func look(_ desk: SupportDesk) async {
        asking = true
        defer { asking = false }
        help = nil
        let text = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let signed = try await desk.open(problem: text, control: control)
            let flow = OfferFlow(link: nil, lookup: app.offerLookup, keys: app.offerKeys)
            flow.present(signed, home: app.cloudHome)
            guard case .review(let offer) = flow.step, offer.isSupport else {
                if case .refused(let e) = flow.step { help = AccessWords.offer(e) }
                return
            }
            flow.control = control
            flow.lengthMs = Self.weekMs
            await flow.approve(access)
            if case .done(let row) = flow.step {
                access.note(row.principal.ticket, problem: text)
                ticket = row.principal.ticket
            }
        } catch {
            help = AccessWords.help(error)
        }
    }
}
