import Foundation
import Testing
@testable import FTWShared

/// The words and buttons of a push. The English is the catalogue's, held to
/// `protocol/push-catalogue.yaml`; the Swedish is the phone's own.
@Suite struct PushTextTests {
    struct Entry: Equatable {
        var kind: String
        var title: String
        var body: String
    }

    static var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FTWSharedTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // FTWKit
            .deletingLastPathComponent() // appleApp
            .deletingLastPathComponent() // repository
    }

    /// The catalogue's events. Its shape is fixed: `- kind:`, `title:` and
    /// `body:` per event, a body in double quotes, comments between.
    static func catalogue() throws -> [Entry] {
        let yaml = try String(contentsOf: repo.appendingPathComponent("protocol/push-catalogue.yaml"), encoding: .utf8)
        var out = [Entry]()
        for line in yaml.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- kind: ") {
                out.append(Entry(kind: String(t.dropFirst(8)), title: "", body: ""))
            } else if t.hasPrefix("title: "), !out.isEmpty {
                out[out.count - 1].title = String(t.dropFirst(7))
            } else if t.hasPrefix("body: "), !out.isEmpty {
                var body = String(t.dropFirst(6))
                if body.hasPrefix("\""), body.hasSuffix("\"") { body = String(body.dropFirst().dropLast()) }
                out[out.count - 1].body = body
            }
        }
        return out
    }

    static func event(_ kind: String, args: [String: String] = [:], src: String? = nil, lp: String? = nil) -> PushAlert {
        PushAlert(.event, home: "fjzyr67buzpyncqmjliwgezvde", kind: kind, args: args, src: src, lp: lp, boot: Data(repeating: 0xb0, count: 16), seq: 9, atMs: 1)
    }

    // MARK: The catalogue

    @Test func theCatalogueIsTheOneTheBoxHas() throws {
        let entries = try Self.catalogue()
        #expect(entries.map(\.kind) == PushKind.all)
        #expect(entries.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
    }

    /// Every kind has both languages, and the English is the catalogue's,
    /// placeholders and all.
    @Test func everyKindHasSwedishAndTheCataloguesEnglish() throws {
        for e in try Self.catalogue() {
            let en = try #require(PushText.en[e.kind], "\(e.kind)")
            let sv = try #require(PushText.sv[e.kind], "\(e.kind)")
            #expect(en.title == e.title, "\(e.kind)")
            #expect(en.body == e.body, "\(e.kind)")
            // Swedish asks for the same arguments, and has the same way out.
            #expect(Self.placeholders(sv.body) == Self.placeholders(en.body), "\(e.kind)")
            #expect((sv.without == nil) == (en.without == nil), "\(e.kind)")
            #expect(Self.placeholders(en.body).isEmpty == (en.without == nil), "\(e.kind)")
            #expect(sv.title != en.title, "\(e.kind)")
        }
        #expect(Set(PushText.en.keys) == Set(PushKind.all))
        #expect(Set(PushText.sv.keys) == Set(PushKind.all))
    }

    static func placeholders(_ s: String) -> [String] {
        s.matches(of: /\{([a-z]+)\}/).map { String($0.1) }.sorted()
    }

    /// Filled, the English reads exactly as the catalogue with its
    /// placeholders filled.
    @Test func filledEnglishIsTheCataloguesSentence() throws {
        let args = ["kwh": "18.4", "target": "80", "by": "07:00", "version": "0.142.0", "phase": "L2"]
        for e in try Self.catalogue() where e.kind != PushKind.boxUnreachable {
            var want = e.body
            for (k, v) in args { want = want.replacingOccurrences(of: "{\(k)}", with: v) }
            want = want.replacingOccurrences(of: "{name}", with: "Easee")
            let home = CloudHome(home: "fjzyr67buzpyncqmjliwgezvde", siteId: "s", boxKey: Data(), sources: ["DUYWWQmn-Xg": "Easee"])
            let got = PushText.content(Self.event(e.kind, args: args, src: "DUYWWQmn-Xg"), sourceName: home.sourceName(opaque: "DUYWWQmn-Xg"), language: .en, decimalSeparator: ".")
            #expect(got == PushText.Content(title: e.title, body: want), "\(e.kind)")
        }
    }

    @Test func theSwedishReadsNaturally() {
        let sv = { (kind: String, args: [String: String], name: String?) in
            PushText.content(Self.event(kind, args: args), sourceName: name, language: .sv, decimalSeparator: ",")
        }
        #expect(sv(PushKind.chargingConnected, [:], nil) == .init(title: "Bilen är inkopplad", body: "Öppna för att se laddningen, kolla bilens nivå och välja klartid."))
        #expect(sv(PushKind.chargingSessionComplete, ["kwh": "18.4"], nil) == .init(title: "Bilen är laddad", body: "18,4 kWh laddat – redo att åka."))
        #expect(sv(PushKind.chargingGoalAtRisk, ["target": "80", "by": "07:00"], nil).body == "Den når inte 80 % till 07:00 i den här takten.")
        #expect(sv(PushKind.updateInstalled, ["version": "0.142.0"], nil).body == "Nu kör den 0.142.0. Allt kom igång igen av sig självt.")
        #expect(sv(PushKind.driverOffline, [:], "Easee").body == "Easee har slutat svara.")
        #expect(sv(PushKind.fuseOverLimit, ["phase": "L2"], nil).body == "L2 drar mer än huvudsäkringen klarar.")
    }

    /// Energy is kWh with the reader's decimal mark. Never a percentage.
    @Test func energyIsKilowattHours() {
        for (sep, want) in [(".", "18.4 kWh delivered — ready to go."), (",", "18,4 kWh delivered — ready to go.")] {
            #expect(PushText.content(Self.event(PushKind.chargingSessionComplete, args: ["kwh": "18.4"]), language: .en, decimalSeparator: sep).body == want)
        }
        #expect(PushText.content(Self.event(PushKind.chargingSessionComplete, args: ["kwh": "7"]), language: .sv, decimalSeparator: ",").body == "7 kWh laddat – redo att åka.")
        for language in PushText.Language.allCases {
            #expect(!PushText.sentences(language)[PushKind.chargingSessionComplete]!.body.contains("%"))
        }
    }

    /// An argument that is missing or will not do gives the sentence
    /// without it, never a half-filled one.
    @Test func aBadArgumentGivesTheSentenceWithoutIt() {
        let cases: [(String, [String: String], String)] = [
            (PushKind.chargingSessionComplete, [:], "Ready to go."),
            (PushKind.chargingSessionComplete, ["kwh": "18.4%"], "Ready to go."),
            (PushKind.chargingSessionComplete, ["kwh": "1e3"], "Ready to go."),
            (PushKind.chargingSessionComplete, ["kwh": "١٨"], "Ready to go."),
            (PushKind.chargingGoalAtRisk, ["target": "180", "by": "07:00"], "It will not reach its goal in time at this pace."),
            (PushKind.chargingGoalAtRisk, ["target": "80", "by": "7:00"], "It will not reach its goal in time at this pace."),
            (PushKind.chargingGoalAtRisk, ["target": "80", "by": "25:00"], "It will not reach its goal in time at this pace."),
            (PushKind.updateInstalled, ["version": "1.0\nCall this number"], "Everything came back on its own."),
            (PushKind.updateInstalled, ["version": String(repeating: "x", count: 41)], "Everything came back on its own."),
            (PushKind.fuseOverLimit, ["phase": ""], "One phase is over the fuse rating."),
            (PushKind.driverOffline, [:], "A device stopped answering."),
        ]
        for (kind, args, body) in cases {
            #expect(PushText.content(Self.event(kind, args: args), language: .en, decimalSeparator: ".").body == body, "\(kind) \(args)")
        }
        // A name comes only from the box's table, never from the event.
        #expect(PushText.content(Self.event(PushKind.driverOffline, args: ["name": "Mallory"]), language: .en).body == "A device stopped answering.")
    }

    @Test func theGenericLineSaysNothingThePushClaimed() {
        #expect(PushText.generic(.sv) == .init(title: "Något hände hemma", body: "Öppna FTW för att se vad."))
        #expect(PushText.generic(.en) == .init(title: "Something happened at home", body: "Open FTW to see what."))
        #expect(PushText.content(PushAlert(.generic, home: "x"), language: .sv) == PushText.generic(.sv))
        #expect(PushText.content(PushAlert(.unreachable, home: "x"), language: .en).title == "Your box is out of reach")
        #expect(PushText.content(PushAlert(.unreachable, home: "x"), language: .sv).title == "Din box går inte att nå")
    }

    /// What Apple shows if the extension never runs: the app's own strings
    /// for the payload's keys, which are the generic line.
    @Test func theAppsFallbackStringsAreTheGenericLine() throws {
        for language in PushText.Language.allCases {
            let file = Self.repo.appendingPathComponent("appleApp/FTW/Intents/\(language.rawValue).lproj/Localizable.strings")
            let strings = try #require(NSDictionary(contentsOf: file) as? [String: String], "\(language)")
            #expect(strings["push.title"] == PushText.generic(language).title, "\(language)")
            #expect(strings["push.generic"] == PushText.generic(language).body, "\(language)")
        }
    }

    @Test func theLanguageIsThePersonsFirst() {
        #expect(PushText.Language.preferred(["sv-SE", "en-US"]) == .sv)
        #expect(PushText.Language.preferred(["SV"]) == .sv)
        #expect(PushText.Language.preferred(["en-SE", "sv-SE"]) == .en)
        #expect(PushText.Language.preferred(["de-DE"]) == .en)
        #expect(PushText.Language.preferred([]) == .en)
    }

    // MARK: Buttons

    @Test func onlyAVerifiedKindPicksButtons() {
        #expect(PushActions.category(for: Self.event(PushKind.chargingConnected)) == .level)
        #expect(PushActions.category(for: Self.event(PushKind.chargingInterrupted)) == .chargeNow)
        #expect(PushActions.category(for: Self.event(PushKind.chargingGoalAtRisk)) == .chargeNow)
        for kind in PushKind.all where ![PushKind.chargingConnected, PushKind.chargingInterrupted, PushKind.chargingGoalAtRisk].contains(kind) {
            #expect(PushActions.category(for: Self.event(kind)) == nil, "\(kind)")
        }
        #expect(PushActions.category(for: PushAlert(.unreachable, home: "x")) == nil)
        // A generic alert carries no kind it could be tricked by.
        #expect(PushActions.category(for: PushAlert(.generic, home: "x", kind: PushKind.chargingConnected)) == nil)
        #expect(PushActions.Category.level.actions == [.level20, .level50, .level80, .open])
        #expect(PushActions.Category.chargeNow.actions == [.chargeNow, .open])
    }

    @Test func aButtonRunsOnlyForTheKindThatOffersIt() {
        let connected = Self.event(PushKind.chargingConnected)
        let atRisk = Self.event(PushKind.chargingGoalAtRisk)
        #expect(PushActions.allows(.level50, for: connected))
        #expect(!PushActions.allows(.chargeNow, for: connected))
        #expect(PushActions.allows(.chargeNow, for: atRisk))
        #expect(!PushActions.allows(.level80, for: atRisk))
        for action in PushActions.Action.allCases {
            #expect(!PushActions.allows(action, for: Self.event(PushKind.cloudGranted)))
            #expect(!PushActions.allows(action, for: PushAlert(.generic, home: "x", kind: PushKind.chargingConnected)))
        }
    }

    /// The levels are the car's level, any whole percent; Charge now is the
    /// Control's command. Open asks the box nothing.
    @Test func whatEachButtonAsks() {
        #expect(PushActions.command(.level20) == .setLevel(pct: 20))
        #expect(PushActions.command(.level50) == .setLevel(pct: 50))
        #expect(PushActions.command(.level80) == .setLevel(pct: 80))
        #expect(PushActions.command(.chargeNow) == .chargeNow)
        #expect(PushActions.command(.open) == nil)
        #expect(PushActions.Action.allCases.filter(PushActions.opensApp) == [.open])
        #expect(PushActions.title(.chargeNow, .sv) == "Ladda nu")
        #expect(PushActions.title(.open, .sv) == "Öppna")
        #expect(PushActions.title(.open, .en) == "Open")
        #expect(PushActions.title(.level50, .sv) == "50 %")
    }

    // MARK: The notice

    @Test func theNoticeSetsEverythingItself() {
        let home = CloudHome(home: "fjzyr67buzpyncqmjliwgezvde", siteId: "site", boxKey: Data(), loadpoints: ["j3HZORNCWHs": "garage"])
        let connected = PushNotice(Self.event(PushKind.chargingConnected, lp: "j3HZORNCWHs"), home: home, language: .en)
        #expect(connected.category == "ftw.level")
        #expect(connected.level == .active)
        #expect(connected.thread == "fjzyr67buzpyncqmjliwgezvde")
        #expect(connected.verified == ["verdict": "event", "home": "fjzyr67buzpyncqmjliwgezvde", "kind": PushKind.chargingConnected, "seq": "9", "atMs": "1", "loadpointID": "garage"])

        let interrupted = PushNotice(Self.event(PushKind.chargingInterrupted), home: home, language: .sv)
        #expect(interrupted.level == .timeSensitive)
        #expect(interrupted.category == "ftw.chargeNow")
        #expect(interrupted.title == "Laddningen avbröts")

        let unreachable = PushNotice(PushAlert(.unreachable, home: "fjzyr67buzpyncqmjliwgezvde"), home: nil, language: .en)
        #expect(unreachable.level == .timeSensitive)
        #expect(unreachable.category == "")
        #expect(unreachable.verified == ["verdict": "unreachable", "home": "fjzyr67buzpyncqmjliwgezvde"])

        let generic = PushNotice(PushAlert(.generic, home: "fjzyr67buzpyncqmjliwgezvde"), home: home, language: .sv)
        #expect(generic.category == "")
        #expect(generic.level == .active)
        #expect(generic.verified.isEmpty)
        #expect(generic.title == "Något hände hemma")
        #expect(PushNotice.generic(.en).category == "")
    }
}
