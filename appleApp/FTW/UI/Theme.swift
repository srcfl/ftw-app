import FTWKit
import SwiftUI

/// The web app's design roles (src/styles/tokens.css), light and dark, so the
/// native app and the box's own page look like one product. Views read
/// roles, never raw colours.
enum Theme {
    static let surface = pair(0xF4F4F2, 0x0D0D0D)
    static let surfaceSunken = pair(0xECECE8, 0x101010)
    static let surfaceRaised = pair(0xFAFAF8, 0x161616)
    static let surfaceElevated = pair(0xFFFFFF, 0x1E1E1E)
    static let line = pair(0xCECEC7, 0x2A2A2A)
    static let fg = pair(0x191919, 0xE8E8E8)
    static let fgDim = pair(0x4F4F4B, 0xA0A0A0)
    static let fgMuted = pair(0x686862, 0x858585)
    static let onAccent = pair(0x0A0A0A, 0x0A0A0A)

    static let accent = pair(0xDA7F00, 0xFFAC41)
    static let importing = pair(0xCC243D, 0xFF6E74)
    static let exporting = pair(0x009639, 0x5FD37F)
    static let generation = pair(0xD48500, 0xFFB000)
    static let storage = pair(0x008FA8, 0x13DCF6)
    static let mobility = pair(0x7F5BB6, 0xCCA8FF)

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

    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        #if os(iOS)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
        #else
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
        #endif
    }
}

#if os(iOS)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

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
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(kind == .quiet ? .regular : .semibold))
            .padding(.vertical, kind == .quiet ? 6 : 11)
            .padding(.horizontal, kind == .quiet ? 4 : 16)
            .frame(maxWidth: kind == .primary || kind == .danger ? .infinity : nil)
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
