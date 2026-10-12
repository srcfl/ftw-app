import FTWKit
import SwiftUI

/// One license file, as the build copied it into the app from the
/// repository root, with its lines joined for a phone's width.
struct LicenseView: View {
    let document: LicenseText.Document
    let source: BuildSource
    private let raw: String?
    private let blocks: [LicenseText.Block]

    init(document: LicenseText.Document, source: BuildSource) {
        self.document = document
        self.source = source
        raw = Bundle.main.url(forResource: document.rawValue, withExtension: nil, subdirectory: "Licenses")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        blocks = raw.map { LicenseText.blocks($0, markdown: document.isMarkdown) } ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if raw == nil {
                    Text(AboutWords.text("This text is missing from this build."))
                        .foregroundStyle(Theme.importing)
                }
                ForEach(blocks) { block in
                    row(block)
                }
            }
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.surface)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let raw {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: raw, preview: SharePreview(document.rawValue))
                }
            }
        }
    }

    @ViewBuilder private func row(_ block: LicenseText.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(Theme.fg)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case .rule:
            Divider().overlay(Theme.line)
        case .paragraph:
            Text(document.isMarkdown ? LicenseText.inline(block.text, base: source.documentBaseURL) : AttributedString(block.text))
                .font(.callout)
                .foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
