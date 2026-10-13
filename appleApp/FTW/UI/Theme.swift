import FTWKit
import SwiftUI

/// The app's side of `Theme` (FTWCharts/Palette.swift holds the palette and
/// type it shares with the widgets): the names the screens read, the energy
/// colour of a flow, the spring and the shapes.
extension Theme {
    // The names from 0.3, pointed at the Phosphor roles so every screen
    // changed at once. New code reads the roles; these go as each screen is
    // rebuilt.
    static let surface = ground
    static let surfaceSunken = hairline
    static let surfaceRaised = raised
    static let surfaceElevated = raised
    static let line = hairline
    static let fg = ink
    static let fgDim = ink2
    static let fgMuted = ink3
    /// Text on an ink fill: inverse video.
    static let onAccent = ground
    /// The interface accent is ink. No orange anywhere.
    static let accent = ink
    static let accentFill = ink
    static let storage = stores
    static let mobility = car

    static let freshLive = live
    /// Not live is ink and holds still; only live gives off colour.
    static let freshStale = ink2
    static let freshLost = ink3

    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 10

    /// One hue per energy kind. The grid is magenta both ways and the home
    /// is ink.
    static func color(_ tone: Flow.Tone) -> Color {
        switch tone {
        case .muted: return ink3
        case .importing, .exporting: return grid
        case .solar: return solar
        case .battery, .charging: return stores
        case .discharging: return gives
        case .ev: return car
        case .house: return ink
        }
    }

    /// A percentage: even digits, and a % that reads as a sign, not a
    /// fixed-width glyph.
    static func percent(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, weight: weight).monospacedDigit()
    }

    /// One spring for everything that moves, so the app moves as one thing.
    static let spring = Animation.spring(duration: 0.35, bounce: 0.15)
}

/// Whether Low Power Mode is on, kept current, for the motion that can
/// wait: the flow's dots slow down and the live curve stops gliding.
@Observable
@MainActor
final class PowerState {
    static let shared = PowerState()
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Notification.Name.NSProcessInfoPowerStateDidChange) {
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

/// A group of lines on the ground. No fill and no border: space, not
/// boxes, separates one group from the next. It keeps the old card's
/// spacing, so nothing moves.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The small caps line over a group, in the terminal's mono.
struct Kicker: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono())
            .tracking(0.5)
            .foregroundStyle(Theme.fgMuted)
            // A label over a card, never louder than what it labels.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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

/// The three button weights. The primary one is inverse video: ink with
/// the ground for its words.
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
        case .danger: return Theme.ground
        case .quiet: return Theme.accent
        case .outline: return Theme.fg
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.accentFill
        case .danger: return Theme.alarm
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
