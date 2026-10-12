import FTWKit
import SwiftUI

/// The web app's design roles (src/styles/tokens.css), light and dark, so the
/// native app and the box's own page look like one product. Views read
/// roles, never raw colours. The values live in `Theme.xcassets`, one colour
/// set per role with its dark variant, so the system switches them.
enum Theme {
    static let surface = Color("ftw.surface")
    static let surfaceSunken = Color("ftw.surfaceSunken")
    static let surfaceRaised = Color("ftw.surfaceRaised")
    static let surfaceElevated = Color("ftw.surfaceElevated")
    static let line = Color("ftw.line")
    static let fg = Color("ftw.fg")
    static let fgDim = Color("ftw.fgDim")
    static let fgMuted = Color("ftw.fgMuted")
    static let onAccent = Color("ftw.onAccent")

    static let accent = Color("ftw.accent")
    static let importing = Color("ftw.importing")
    static let exporting = Color("ftw.exporting")
    static let generation = Color("ftw.generation")
    static let storage = Color("ftw.storage")
    static let mobility = Color("ftw.mobility")

    static let freshLive = exporting
    static let freshStale = generation
    static let freshLost = fgMuted

    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 10

    static func color(_ tone: Flow.Tone) -> Color {
        switch tone {
        case .muted: return fgMuted
        case .importing: return importing
        case .exporting: return exporting
        case .solar: return generation
        case .battery, .charging, .discharging: return storage
        case .ev: return mobility
        case .house: return accent
        }
    }

    /// Mono figures, as the web app sets every number, so a value that
    /// changes every second does not shift the line under the reader's eye.
    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// A percentage: even digits, and a % that reads as a sign, not a
    /// fixed-width glyph.
    static func percent(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, weight: weight).monospacedDigit()
    }

    /// One spring for everything that moves, so the app moves as one thing.
    static let spring = Animation.spring(duration: 0.35, bounce: 0.15)
}

/// A raised card, the web app's `.card`.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// The small caps line over a card title.
struct Kicker: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.fgMuted)
    }
}

/// A sentence under a control: what happened, or what to do.
struct Hint: View {
    let text: String
    var tone: Color = Theme.fgDim
    init(_ text: String, tone: Color = Theme.fgDim) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The web app's three button weights.
struct FTWButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, outline, danger }
    var kind: Kind
    var wide = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(kind == .quiet ? .regular : .semibold))
            .padding(.vertical, kind == .quiet ? 6 : 11)
            .padding(.horizontal, kind == .quiet ? 4 : 16)
            .frame(maxWidth: wide || kind == .primary || kind == .danger ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay {
                if kind == .outline {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(Theme.line, lineWidth: 1)
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onAccent
        case .danger: return .white
        case .quiet: return Theme.accent
        case .outline: return Theme.fg
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.accent
        case .danger: return Theme.importing
        case .quiet, .outline: return .clear
        }
    }
}

extension ButtonStyle where Self == FTWButtonStyle {
    static var primary: FTWButtonStyle { FTWButtonStyle(kind: .primary) }
    static var quiet: FTWButtonStyle { FTWButtonStyle(kind: .quiet) }
    static var outline: FTWButtonStyle { FTWButtonStyle(kind: .outline) }
    static var danger: FTWButtonStyle { FTWButtonStyle(kind: .danger) }
    /// The second choice beside a primary one, as wide as it.
    static var secondary: FTWButtonStyle { FTWButtonStyle(kind: .outline, wide: true) }
}

/// A pressed-button choice between a few options, the web app's range picker.
struct Segments<T: Hashable>: View {
    let options: [T]
    let selected: T
    let label: (T) -> String
    let choose: (T) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button { choose(option) } label: {
                    Text(label(option))
                        .font(.footnote.weight(.semibold))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .foregroundStyle(option == selected ? Theme.onAccent : Theme.fgDim)
                        .background(option == selected ? Theme.accent : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.surfaceSunken, in: Capsule())
    }
}

/// Clock time in the phone's own style.
enum Clock {
    static func time(_ ms: Double) -> String {
        Date(timeIntervalSince1970: ms / 1000).formatted(date: .omitted, time: .shortened)
    }

    static func dayAndTime(_ ms: Double) -> String {
        Date(timeIntervalSince1970: ms / 1000).formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func day(_ ms: Double) -> String {
        Date(timeIntervalSince1970: ms / 1000).formatted(date: .long, time: .omitted)
    }
}

/// The app's words in the phone's language, English or Swedish (FTWKit's
/// `NodeWords`, then `AppWords`). Text built from a String is shown as given.
func L(_ en: String) -> String { NodeWords.text(en) }
