import Foundation

/// The words of a push, written on the phone from the event's kind and
/// arguments, in Swedish or English (Fredrik, 12 Oct 2026). The box sends
/// codes and the service sends none of its own, so a lock screen never
/// shows a sentence this file does not hold.
///
/// The English is the push catalogue's (`protocol/push-catalogue.yaml`,
/// the same file as in srcfl/ftw), and a test holds it to that file.
public enum PushText {
    public enum Language: String, Sendable, CaseIterable {
        case sv, en

        /// The person's first language: Swedish if it is Swedish, else
        /// English.
        public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> Language {
            languages.first?.lowercased().hasPrefix("sv") == true ? .sv : .en
        }
    }

    public struct Content: Sendable, Equatable {
        public var title: String
        public var body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// One kind's sentence. `{name}` marks an argument; `without` is the
    /// body to show when an argument is missing or will not do.
    struct Sentence {
        var title: String
        var body: String
        var without: String?
    }

    /// The line for anything that did not check out: no signature, an old
    /// event, a home this phone does not hold. It says nothing the push
    /// claimed.
    public static func generic(_ language: Language) -> Content {
        switch language {
        case .sv: return Content(title: "Något hände hemma", body: "Öppna FTW för att se vad.")
        case .en: return Content(title: "Something happened at home", body: "Open FTW to see what.")
        }
    }

    /// The words for a checked alert. `sourceName` is the device's name from
    /// the box, for an event about a device.
    public static func content(_ alert: PushAlert, sourceName: String? = nil, language: Language, decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> Content {
        let kind: String
        switch alert.verdict {
        case .generic: return generic(language)
        case .unreachable: kind = PushKind.boxUnreachable
        case .event: kind = alert.kind
        }
        guard let s = sentences(language)[kind] else { return generic(language) }
        let values = arguments(alert.args, name: sourceName, decimalSeparator: decimalSeparator)
        guard let body = fill(s.body, values) else { return Content(title: s.title, body: s.without ?? s.body) }
        return Content(title: s.title, body: body)
    }

    static func sentences(_ language: Language) -> [String: Sentence] {
        language == .sv ? sv : en
    }

    static let en: [String: Sentence] = [
        PushKind.chargingConnected: Sentence(title: "Car plugged in", body: "Open to see charging status, check the battery level and set a ready time."),
        PushKind.chargingSessionComplete: Sentence(title: "Car charged", body: "{kwh} kWh delivered — ready to go.", without: "Ready to go."),
        PushKind.chargingGoalAtRisk: Sentence(title: "The car may not be ready", body: "It will not reach {target} % by {by} at this pace.", without: "It will not reach its goal in time at this pace."),
        PushKind.chargingInterrupted: Sentence(title: "Charging stopped early", body: "The car stopped charging before it was done."),
        PushKind.updateInstalled: Sentence(title: "Your box updated itself", body: "Now running {version}. Everything came back on its own.", without: "Everything came back on its own."),
        PushKind.driverOffline: Sentence(title: "A device went quiet", body: "{name} stopped answering.", without: "A device stopped answering."),
        PushKind.fuseOverLimit: Sentence(title: "The house is drawing too much", body: "{phase} is over the fuse rating.", without: "One phase is over the fuse rating."),
        PushKind.boxUnreachable: Sentence(title: "Your box is out of reach", body: "It stopped answering. Power cut, or the internet at home is down."),
        PushKind.cloudGranted: Sentence(title: "FTW Cloud is on", body: "Your box now shares a copy of its readings with FTW Cloud. You can turn it off in the app or on the box."),
        PushKind.cloudRevoked: Sentence(title: "FTW Cloud is off", body: "Your box stopped sharing with FTW Cloud and asked it to delete its copy."),
    ]

    static let sv: [String: Sentence] = [
        PushKind.chargingConnected: Sentence(title: "Bilen är inkopplad", body: "Öppna för att se laddningen, kolla bilens nivå och välja klartid."),
        PushKind.chargingSessionComplete: Sentence(title: "Bilen är laddad", body: "{kwh} kWh laddat – redo att åka.", without: "Redo att åka."),
        PushKind.chargingGoalAtRisk: Sentence(title: "Bilen kanske inte blir klar", body: "Den når inte {target} % till {by} i den här takten.", without: "Den når inte målet i tid i den här takten."),
        PushKind.chargingInterrupted: Sentence(title: "Laddningen avbröts", body: "Bilen slutade ladda innan den var klar."),
        PushKind.updateInstalled: Sentence(title: "Din box har uppdaterat sig", body: "Nu kör den {version}. Allt kom igång igen av sig självt.", without: "Allt kom igång igen av sig självt."),
        PushKind.driverOffline: Sentence(title: "En enhet har tystnat", body: "{name} har slutat svara.", without: "En enhet har slutat svara."),
        PushKind.fuseOverLimit: Sentence(title: "Huset drar för mycket ström", body: "{phase} drar mer än huvudsäkringen klarar.", without: "En fas drar mer än huvudsäkringen klarar."),
        PushKind.boxUnreachable: Sentence(title: "Din box går inte att nå", body: "Den har slutat svara. Strömavbrott, eller så är internet hemma nere."),
        PushKind.cloudGranted: Sentence(title: "FTW Cloud är på", body: "Din box delar nu en kopia av sina mätvärden med FTW Cloud. Du kan stänga av det i appen eller på boxen."),
        PushKind.cloudRevoked: Sentence(title: "FTW Cloud är av", body: "Din box har slutat dela med FTW Cloud och bett den radera sin kopia."),
    ]

    /// The arguments that will do, ready to show. The box signed them, and
    /// they still pass a check: a lock screen is no place for a stray line
    /// break or a paragraph.
    static func arguments(_ args: [String: String], name: String?, decimalSeparator: String) -> [String: String] {
        var out = [String: String]()
        // Energy is kWh with the reader's decimal mark, never a percentage.
        if let kwh = args["kwh"], kwh.wholeMatch(of: /[0-9]{1,5}(\.[0-9]{1,3})?/) != nil {
            out["kwh"] = kwh.replacingOccurrences(of: ".", with: decimalSeparator)
        }
        if let target = args["target"], target.wholeMatch(of: /[0-9]{1,3}/) != nil, let pct = Int(target), pct <= 100 {
            out["target"] = String(pct)
        }
        if let by = args["by"], let m = by.wholeMatch(of: /([0-9]{2}):([0-9]{2})/), let h = Int(m.1), let min = Int(m.2), h < 24, min < 60 {
            out["by"] = by
        }
        for key in ["version", "phase"] {
            if let v = args[key].flatMap(plain) { out[key] = v }
        }
        if let name = name.flatMap(plain) { out["name"] = name }
        return out
    }

    /// A short line of text, or nil.
    static func plain(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(t.count), t.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else { return nil }
        return t
    }

    /// The template with every `{name}` filled, or nil if one has no value.
    static func fill(_ template: String, _ values: [String: String]) -> String? {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}"), let value = values[String(rest[rest.index(after: open)..<close])] else { return nil }
            out += rest[..<open] + value
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
