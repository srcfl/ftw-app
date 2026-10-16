import FTWKit
import SwiftUI

/// What assistants, support and owners did, newest first, as the box wrote
/// it. A support call names the person at Sourceful who made it, as FTW
/// Cloud named them: the box cannot check that, and the line says so.
struct AuditView: View {
    let access: AccessModel

    var body: some View {
        List {
            ForEach(access.audit) { row in
                AuditLine(access: access, row: row)
            }
            if access.audit.isEmpty {
                Text(AccessWords.text("Nothing has happened yet."))
                    .foregroundStyle(Theme.ink2)
            }
            if access.auditMore {
                Button(AccessWords.text("Load older")) { Task { await access.loadAudit(more: true) } }
                    .accessibilityIdentifier("audit.more")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle(AccessWords.text("Activity"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await access.loadAudit() }
        .refreshable { await access.loadAudit() }
    }
}

struct AuditLine: View {
    let access: AccessModel
    let row: AuditRow

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccessWords.actor(row, me: access.signedFor.deviceID, agents: access.list?.agents ?? []))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(AppWords.day(Double(row.atMs), nowMs: now, zone: .current))
                    .font(Theme.mono(.caption))
                    .foregroundStyle(Theme.ink2)
            }
            Text(AccessWords.what(row))
            if let by = AccessWords.by(row) {
                Label(by, systemImage: "person.badge.shield.checkmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
            }
            if let result = AccessWords.result(row) {
                Text(result).font(.footnote).foregroundStyle(row.result == "declined" ? Theme.ink2 : Theme.alarm)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
