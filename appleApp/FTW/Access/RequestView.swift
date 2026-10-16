import FTWKit
import SwiftUI

/// A lasting change an assistant asked for: exactly what it asks, each
/// value under the registry's label for it, and its reason in its own
/// words. Approving signs those very values with Face ID; declining is one
/// tap.
struct RequestView: View {
    let access: AccessModel
    let request: AgentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var answered: Bool?

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AccessWords.format("%@ asks to", access.agentName(request.agent)))
                        .foregroundStyle(Theme.ink2)
                    Text(AccessWords.op(request.op)).font(.title2.weight(.bold))
                }
                .padding(.vertical, 4)
                ForEach(Array(AccessWords.arguments(request, modes: access.site.session.modes).enumerated()), id: \.offset) { _, line in
                    LabeledContent(line.label, value: line.value)
                }
            }

            let why = AccessWords.clean(request.why).trimmingCharacters(in: .whitespaces)
            if !why.isEmpty {
                Section {
                    Text("“\(why)”").italic()
                } header: {
                    Text(AccessWords.text("In its own words"))
                } footer: {
                    Text(AccessWords.format("Asked %@", AppWords.day(Double(request.atMs), nowMs: now, zone: .current)))
                }
            }

            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if AccessWords.approvable(request) {
                        Text(AccessWords.text("Approving runs it on your box now, as if you had made the change yourself."))
                    } else {
                        Text(AccessWords.text("This request has something this app can't show you, so it can only be declined."))
                            .foregroundStyle(Theme.alarm)
                    }
                    Text(AccessWords.format("Waits %@", AppWords.day(Double(request.expiresAtMs), nowMs: now, zone: .current)))
                    if let help = access.help { Text(help).foregroundStyle(Theme.alarm) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle(access.agentName(request.agent))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if AccessWords.approvable(request) {
                    Button { answer(true) } label: {
                        HStack(spacing: 8) {
                            if access.working == request.reqId { ProgressView().tint(Theme.onAccent) } else { Image(systemName: Biometry.symbol) }
                            Text(AccessWords.format("Approve with %@", AccessWords.biometry))
                        }
                    }
                    .buttonStyle(FTWButtonStyle(kind: .primary))
                    .accessibilityIdentifier("request.approve")
                }
                Button(AccessWords.text("Decline")) { answer(false) }
                    .buttonStyle(FTWButtonStyle(kind: .quiet))
                    .accessibilityIdentifier("request.decline")
            }
            .disabled(access.working != nil)
            .padding(16)
            .background(Theme.surface)
        }
        .sensoryFeedback(trigger: answered) { _, now in now == true ? .success : nil }
    }

    private func answer(_ approve: Bool) {
        Task {
            if await access.answer(request, approve: approve) {
                answered = true
                dismiss()
            }
        }
    }
}
