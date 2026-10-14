import Foundation

/// How far the box has confirmed one car command, as the receipt log
/// `SENT ▸ ACCEPTED ▸ MEASURED ▸ CONFIRMED`: four reserved slots, each lit
/// only on its own evidence.
///
/// - SENT: this phone sent the command.
/// - ACCEPTED: the box has it (`cmd.ack`).
/// - MEASURED: once the box has it, lane 0 shows the car drawing more than
///   `drawingW`.
/// - CONFIRMED: the box did it (`cmd.result`).
///
/// The slots light in the order their evidence comes, not in the order
/// they are written: the box often confirms before the car draws. A refusal
/// takes the last slot, in alarm red, with the box's reason. The car view,
/// the Live Activity and the watch read the same rules.
public struct ReceiptLog: Equatable, Hashable, Codable, Sendable {
    public enum Slot: String, CaseIterable, Codable, Sendable {
        case sent, accepted, measured, confirmed
    }

    public var sent: Bool
    public var accepted: Bool
    public var measured: Bool
    public var confirmed: Bool
    /// The box's reason, ready to show. Set, it takes the last slot.
    public var refused: String?
    /// The slots this command has. A level is not measured on lane 0, so
    /// its receipt has no MEASURED.
    public var slots: [Slot]

    public init(sent: Bool = true, accepted: Bool = false, measured: Bool = false, confirmed: Bool = false, refused: String? = nil, slots: [Slot] = Slot.allCases) {
        self.sent = sent
        self.accepted = accepted
        self.measured = measured
        self.confirmed = confirmed
        self.refused = refused
        self.slots = slots
    }

    /// Above this the car draws power: the threshold Now uses for a beam.
    public static let drawingW: Double = 42

    /// Whether lane 0's car power is evidence that the car draws.
    public static func measures(evW: Double?, live: Bool) -> Bool {
        guard live, let evW else { return false }
        return evW > drawingW
    }

    public func lit(_ slot: Slot) -> Bool {
        switch slot {
        case .sent: return sent
        case .accepted: return accepted
        case .measured: return measured
        case .confirmed: return confirmed && refused == nil
        }
    }

    /// The slots as the line shows them, each with its word and whether it
    /// is lit. The last slot is REFUSED once the box refused. Every word is
    /// padded to the width its slot reserves, so a slot that lights or
    /// turns to REFUSED never moves the others.
    public var marks: [Mark] {
        slots.map { slot in
            if slot == .confirmed, refused != nil {
                return Mark(slot: slot, text: Self.reserved(.confirmed, ReceiptWord.refused.text), state: .refused)
            }
            return Mark(slot: slot, text: Self.reserved(slot, Self.word(slot)), state: lit(slot) ? .lit : .waiting)
        }
    }

    public struct Mark: Equatable, Sendable {
        public enum State: Equatable, Sendable { case waiting, lit, refused }
        public let slot: Slot
        public let text: String
        public let state: State
    }

    /// "SENT", "ACCEPTED", "MEASURED", "CONFIRMED", in the terminal's caps.
    public static func word(_ slot: Slot) -> String {
        switch slot {
        case .sent: return ReceiptWord.sent.text
        case .accepted: return ReceiptWord.accepted.text
        case .measured: return ReceiptWord.measured.text
        case .confirmed: return ReceiptWord.confirmed.text
        }
    }

    /// The arrow between slots.
    public static let arrow = " ▸ "

    /// The whole line as plain text, for VoiceOver and a test.
    public var line: String { marks.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: Self.arrow) }

    /// A word padded with spaces to its slot's width. The last slot holds
    /// either CONFIRMED or REFUSED, so it reserves the longer.
    static func reserved(_ slot: Slot, _ text: String) -> String {
        let width = slot == .confirmed ? max(ReceiptWord.confirmed.text.count, ReceiptWord.refused.text.count) : text.count
        return text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
    }
}

/// The receipt's words. The English is the key; the Swedish lives in
/// `Resources/sv.lproj`, and a test checks each one has it.
enum ReceiptWord: String, CaseIterable {
    case sent = "SENT"
    case accepted = "ACCEPTED"
    case measured = "MEASURED"
    case confirmed = "CONFIRMED"
    case refused = "REFUSED"

    var text: String { Words.text(rawValue) }
}
