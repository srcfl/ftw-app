import FTWKit
import SwiftUI
import UniformTypeIdentifiers

/// The energy tax refund after battery storage, one calendar year at a
/// time: the figure to give Skatteverket in whole kWh, the hours behind
/// it, the battery it was counted with, the year month by month, and the
/// hourly basis to keep with the application. Every figure is the box's
/// and none is live: the box counts a year that has passed, or as much of
/// it as has. It opens on the last answer, dated, and asks the box only
/// when the year or the hour changes.
struct BatteryReturnView: View {
    @Bindable var model: BatteryReturnModel

    var body: some View {
        ScrollView {
            BatteryReturnPage(glance: model.glance, year: model.year, model: model)
                .equatable()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 640, alignment: .topLeading)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.ground)
        .navigationTitle(BatteryReturnWords.text("Energy tax refund"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                YearPicker(model: model)
            }
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        #if DEBUG
        .task {
            // `-FTWRefundYear 2024` opens on another year, so each can be
            // photographed.
            let year = UserDefaults.standard.integer(forKey: "FTWRefundYear")
            if model.years.contains(year) { model.year = year }
        }
        #endif
    }
}

/// The year on screen, from the running one back to the oldest an owner
/// can still apply for.
private struct YearPicker: View {
    @Bindable var model: BatteryReturnModel

    var body: some View {
        let years = model.years
        Menu {
            Picker(selection: $model.year) {
                ForEach(years, id: \.self) { year in
                    Text(verbatim: year == years.first ? BatteryReturnWords.format("%@ so far", String(year)) : String(year))
                        .tag(year)
                }
            } label: {
                Text(BatteryReturnWords.text("Year"))
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: String(model.year))
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
        }
        .accessibilityLabel(BatteryReturnWords.text("Year"))
        .accessibilityValue(String(model.year))
        .accessibilityIdentifier("refund.year")
    }
}

/// The page for one year, redrawn only when what it says changes.
private struct BatteryReturnPage: View, Equatable {
    let glance: BatteryReturnGlance
    let year: Int
    let model: BatteryReturnModel
    @ScaledMetric(relativeTo: .largeTitle) private var figureSize: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var unitSize: CGFloat = 20

    nonisolated static func == (a: Self, b: Self) -> Bool { a.glance == b.glance && a.year == b.year }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            if glance.hasBasis {
                VStack(alignment: .leading, spacing: 6) {
                    ShareLink(item: BatteryReturnBasis(year: year, model: model), preview: SharePreview(BatteryReturn.basisName(year))) {
                        Label(BatteryReturnWords.text("Hourly basis (CSV)"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("refund.basis")
                    Text(BatteryReturnWords.text("Keep it with your application."))
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.top, 20)
            }
            if !glance.months.isEmpty {
                Kicker(BatteryReturnWords.text("By month"))
                    .padding(.top, 28)
                    .padding(.bottom, 2)
                ForEach(Array(glance.months.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().overlay(Theme.line) }
                    MonthRow(row: row)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(BatteryReturnWords.text("Where the readings can't tell where energy went, FTW counts low. The figure assumes FTW reads every solar inverter, battery and charger in the home."))
                Text(BatteryReturnWords.text("You can apply up to three years after the year ends, and your box keeps the hourly readings that long."))
                Link(BatteryReturnWords.text("Skatteverket's rules"), destination: BatteryReturn.rulesURL)
                    .foregroundStyle(Theme.ink)
                    .underline()
            }
            .font(.footnote)
            .foregroundStyle(Theme.ink3)
            .padding(.top, 28)
        }
        .animation(Theme.spring, value: glance)
    }

    /// "1 234 kWh", what it is, when the box worked it out, and the lines
    /// behind it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(glance.figure)
                    .font(Theme.figure(figureSize))
                    .tracking(-1)
                    .foregroundStyle(glance.figure == "—" ? Theme.ink3 : Theme.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(glance.unit)
                    .font(.system(size: unitSize, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Text(glance.word)
                .font(.headline)
                .foregroundStyle(Theme.ink2)
            // `AS OF 14:32`, or kept on this phone: the box's last word,
            // dated.
            Text(glance.footer)
                .font(Theme.mono())
                .tracking(0.5)
                .foregroundStyle(Theme.ink3)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(glance.lines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 12)
        }
        .redacted(reason: glance.placeholder ? .placeholder : [])
        .accessibilityElement(children: .combine)
    }
}

/// One month: its name, what went back, and how many of its hours count.
private struct MonthRow: View {
    let row: BatteryReturnGlance.Row
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The figure goes under the name at the accessibility sizes,
            // chosen by the size and never by a fit, so every month reads
            // the same way.
            if typeSize.isAccessibilitySize {
                name
                figure
            } else {
                HStack(alignment: .firstTextBaseline) {
                    name
                    Spacer(minLength: 8)
                    figure
                }
            }
            Text(row.hours)
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        Text(row.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.ink)
    }

    private var figure: some View {
        Text(row.figure)
            .font(.subheadline)
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
    }
}

/// The hourly basis behind one year, read from the box when the share
/// sheet asks for the file.
struct BatteryReturnBasis: Transferable {
    let year: Int
    let model: BatteryReturnModel

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { basis in
            SentTransferredFile(try await basis.model.basis(basis.year))
        }
    }
}
