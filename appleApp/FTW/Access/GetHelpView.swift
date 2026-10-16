import FTWKit
import SwiftUI

/// Get help: the owner says what is wrong, and Sourceful's help desk opens
/// a ticket and answers with Sourceful's signed offer for it. The owner
/// then sees that offer as it will be signed, the same page an assistant's
/// gets: what Sourceful may read, control as its own switch, off, and for
/// how long. One Face ID grants it, tied to the ticket; it ends when the
/// ticket closes, when its time runs out or when the owner removes it.
///
/// There is no help desk behind the app yet. A release build says so and
/// offers nothing to press; the simulated home has a desk of its own.
struct GetHelpView: View {
    let app: AppModel
    let access: AccessModel
    @State private var problem = ""
    @State private var flow: OfferFlow?
    @State private var reviewing = false
    @State private var asking = false
    @State private var help: String?
    @FocusState private var writing: Bool

    var body: some View {
        let desk = app.desk
        List {
            Section(AccessWords.text("Describe the problem")) {
                TextField(AccessWords.text("What happened, and when?"), text: $problem, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($writing)
                    .accessibilityIdentifier("help.problem")
            }
            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AccessWords.text("Your words go to Sourceful's help desk with the ticket. Your box never sees them."))
                    Text(AccessWords.format("Next you see what Sourceful asks to do, and approve it with %@.", AccessWords.biometry))
                    Text(AccessWords.text("Every call names the person at Sourceful who made it. You can remove the access at any time, and it ends when the ticket closes."))
                    if !desk.isOpen { Text(AccessWords.text("Sourceful can't open a ticket from the app yet.")).foregroundStyle(Theme.alarm) }
                    if let help { Text(help).foregroundStyle(Theme.alarm) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.surface)
        .navigationTitle(AccessWords.text("Get help"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(AccessWords.text("Done")) { writing = false }
                    .accessibilityIdentifier("help.written")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await ask(desk) } } label: {
                HStack(spacing: 8) {
                    if asking { ProgressView().tint(Theme.onAccent) }
                    Text(AccessWords.text("Let Sourceful look"))
                }
            }
            .buttonStyle(FTWButtonStyle(kind: .primary))
            .disabled(!desk.isOpen || asking || problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !access.available)
            .padding(16)
            .background(Theme.surface)
            .accessibilityIdentifier("help.look")
        }
        .navigationDestination(isPresented: $reviewing) {
            if let flow { OfferFlowView(app: app, flow: flow) }
        }
    }

    /// The desk opens the ticket with the owner's words and hands back
    /// Sourceful's signed offer, which is checked like any other and shown
    /// as it will be signed.
    private func ask(_ desk: SupportDesk) async {
        asking = true
        defer { asking = false }
        help = nil
        let text = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let signed = try await desk.open(problem: text)
            let next = OfferFlow(link: nil, lookup: app.offerLookup, keys: app.offerKeys)
            next.present(signed, home: app.cloudHome)
            guard case .review(let offer) = next.step, offer.isSupport else {
                if case .refused(let e) = next.step { help = AccessWords.offer(e) }
                return
            }
            next.onDone = { row in
                access.note(row.principal.ticket, problem: text)
                problem = ""
            }
            flow = next
            reviewing = true
        } catch {
            help = AccessWords.help(error)
        }
    }
}
