import Foundation

/// The words of Access, Get help and the approval sheets, in English or
/// Swedish, with the language `AppWords` uses. A scope, an op or an argument
/// is named by what it lets someone do, never by its registry name.
public enum AccessWords {
    /// What this phone unlocks with, as the system names it: "Face ID" or
    /// "Touch ID". The app sets it once at launch.
    nonisolated(unsafe) public static var biometry = "Face ID"

    public static func text(_ en: String) -> String {
        AppWords.language == .sv ? (sv[en] ?? en) : en
    }

    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    // MARK: Who

    /// The name a client gives itself, quoted: its own word, never checked.
    /// Only a support grant, which the box takes from Sourceful's client
    /// alone, is called Sourceful support. A name that claims Sourceful or
    /// FTW is no name.
    public static func clientName(_ offer: GrantOffer) -> String {
        if offer.isSupport { return text("Sourceful support") }
        return ownName(offer.client) ?? format("Assistant at %@", offer.clientHost)
    }

    public static func name(_ row: AgentRow) -> String {
        if row.isSupport { return text("Sourceful support") }
        return ownName(row.principal.client) ?? format("Assistant %@", row.id)
    }

    /// The client's name, cleaned and quoted, or nil when it has none it
    /// may use: empty, or one that names Sourceful or FTW.
    public static func ownName(_ raw: String) -> String? {
        let name = clean(raw).trimmingCharacters(in: .whitespaces)
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        guard !name.isEmpty, !folded.contains("sourceful"), !folded.contains("ftw") else { return nil }
        return "“\(name.prefix(64))”"
    }

    /// Whether a client's own name was set aside because it named Sourceful
    /// or FTW.
    public static func nameHidden(_ raw: String) -> Bool {
        !clean(raw).trimmingCharacters(in: .whitespaces).isEmpty && ownName(raw) == nil
    }

    /// Text from outside, with control and format characters taken out:
    /// no bidi overrides, no zero-width joiners, no line breaks.
    public static func clean(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.map { s -> Unicode.Scalar in
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return " "
            default: return s
            }
        }))
    }

    /// A whole number from outside, or nil when it is none or too large to
    /// mean anything here.
    static func whole(_ d: Double) -> Int? {
        guard d.isFinite, d.rounded() == d, abs(d) < 1e12 else { return nil }
        return Int(d)
    }

    /// Where the client lives, when its id is an address: the host of its
    /// metadata document. A registered client's id is no address, and
    /// names nothing.
    public static func host(_ row: AgentRow) -> String {
        guard let url = URL(string: row.principal.clientId), url.scheme == "https", let host = url.host else { return "" }
        return host
    }

    // MARK: Rights

    /// What a scope lets an agent do, in plain words.
    public static func scope(_ name: String) -> String {
        text(scopeWords[name] ?? Contract.scopeDescs[name] ?? name)
    }

    static let scopeWords: [String: String] = [
        "ftw.live.read": "See live readings",
        "ftw.history.read": "See history",
        "ftw.plan.read": "See the plan and prices",
        "ftw.health.read": "See how the box and its devices are doing",
        "ftw.events.read": "See events",
        "ftw.logs.read": "Read the box's log, with names taken out",
        "ftw.config.read": "Read the settings, with names and secrets taken out",
        "ftw.diag.run": "Read full diagnostics, source, logs and backups, which can contain saved credentials",
        "ftw.setup.write": "Save confirmed setup and restart to apply it when you confirm",
        "ftw.dispatch.hold": "Charge the car for a short while",
        "ftw.goals.request": "Ask you for lasting changes",
    ]

    /// The scopes an owner reads in a list: what it reads first, control
    /// after, in the registry's order.
    public static func ordered(_ scopes: [String]) -> [String] {
        let order = Contract.agentRoleScopes[Contract.roleAgent] ?? []
        return scopes.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }

    /// One line for a grant: "Reads" or "Reads and controls".
    public static func summary(_ scopes: [String]) -> String {
        if scopes.contains(AccessWire.scopeSetup) {
            return text(AccessWire.controlScopes.isDisjoint(with: scopes) ? "Reads and setup" : "Reads, setup and control")
        }
        return AccessWire.controlScopes.isDisjoint(with: scopes) ? text("Reads") : text("Reads and controls")
    }

    /// What control means for these caps: how long and how hard it may
    /// charge, and that lasting changes wait for the owner.
    public static func control(_ caps: Caps, scopes: [String]) -> String {
        var parts = [String]()
        if scopes.contains(AccessWire.scopeHold) {
            parts.append(format("It may charge the car for up to %@ at a time, at most %@.", minutes(Double(caps.holdS)), AppWords.power(Double(caps.maxW))))
        }
        if scopes.contains(AccessWire.scopeRequest) {
            parts.append(format("Lasting changes, such as the mode or a goal, wait for your %@.", biometry))
        }
        return parts.joined(separator: " ")
    }

    /// What an op does, in plain words.
    public static func op(_ name: String) -> String {
        text(opWords[name] ?? Contract.opDescs[name] ?? name)
    }

    static let opWords: [String: String] = [
        "site.mode.set": "Change how the home is run",
        "planner.prefs.set": "Change the plan's settings",
        "loadpoint.hold": "Charge the car now",
        "loadpoint.soc.set": "Correct the car's level",
        "loadpoint.surplus_only.set": "Charge the car from solar only",
        "car.goal.set": "Change when and how far the car charges",
        "car.soc.set": "Set the car's level",
    ]

    /// Whether the app can show every part of a request as the registry
    /// names it: a known op open to agents, every key one the registry
    /// lists for it, each value of its kind. Anything else may only be
    /// declined.
    public static func approvable(_ request: AgentRequest) -> Bool {
        guard Contract.agentOps[request.op] != nil, let defs = Contract.agentArgs[request.op],
              let given = request.args.entries ?? (request.args.isNull ? [] : nil) else { return false }
        for e in given {
            guard let key = e.key.string, let def = defs.first(where: { $0.name == key }), fits(e.value, def) else { return false }
        }
        return true
    }

    static func fits(_ v: CBOR, _ def: Contract.AgentArg) -> Bool {
        switch def.kind {
        case "mode", "loadpoint", "car":
            return v.string.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? false
        case "enum":
            return v.string.map(def.values.contains) ?? false
        case "bool":
            return v.bool != nil
        default:
            guard let d = v.double, d.isFinite else { return false }
            if let min = def.min, d < min { return false }
            if let max = def.max, d > max { return false }
            if def.name == "ready_by_min" || def.name == "days" { return whole(d) != nil }
            return abs(d) < 1e12
        }
    }

    /// A request's arguments, each by its registry label, in the registry's
    /// order, then anything the registry does not name.
    public static func arguments(_ request: AgentRequest, modes: [ModeInfo] = []) -> [(label: String, value: String)] {
        let defs = Contract.agentArgs[request.op] ?? []
        let given = request.args.entries ?? []
        var out = [(label: String, value: String)]()
        for def in defs {
            guard let v = given.first(where: { $0.key.string == def.name })?.value else { continue }
            out.append((text(def.label), value(v, def, modes: modes)))
        }
        for e in given where !defs.contains(where: { $0.name == e.key.string }) {
            out.append((clean(e.key.string ?? "?"), raw(e.value)))
        }
        return out
    }

    static func value(_ v: CBOR, _ def: Contract.AgentArg, modes: [ModeInfo]) -> String {
        // A number from outside that is no number here is shown as sent.
        if let d = v.double, !d.isFinite || abs(d) >= 1e12 { return raw(v) }
        switch def.kind {
        case "mode":
            guard let key = v.string else { return raw(v) }
            if let m = modes.first(where: { $0.key == key }) { return ModeWords.name(m) }
            return ModeWords.names[key].map(NodeWords.text) ?? key
        case "enum":
            guard let s = v.string else { return raw(v) }
            return text(enumWords[s] ?? s)
        case "bool":
            guard let b = v.bool else { return raw(v) }
            return text(b ? "Yes" : "No")
        case "ratio":
            guard let d = v.double else { return raw(v) }
            return AppWords.percent(d * 100)
        case "power":
            guard let d = v.double else { return raw(v) }
            return AppWords.power(d)
        case "duration":
            guard let d = v.double else { return raw(v) }
            return minutes(d)
        case "loadpoint", "car":
            // The agent's own id for it. Only the box can tell which one.
            return raw(v)
        default:
            guard let d = v.double else { return raw(v) }
            switch def.name {
            case "ready_by_min": return whole(d).map { AppWords.clock(minute: $0) } ?? raw(v)
            case "days": return whole(d).map(EVText.days) ?? raw(v)
            default: return AppWords.decimal(whole(d).map(String.init) ?? String(d))
            }
        }
    }

    static let enumWords: [String: String] = [
        "unknown": "Not set",
        "not_allowed": "No",
        "allowed": "Yes",
        "auto": "Automatic",
        "1p": "One phase",
        "3p": "Three phases",
    ]

    static func raw(_ v: CBOR) -> String {
        switch v {
        case .text(let s): return String(clean(s).prefix(80))
        case .bool(let b): return b ? "true" : "false"
        case .unsigned, .negative, .double: return v.double.map { whole($0).map(String.init) ?? String($0) } ?? "?"
        case .bytes(let b): return Base64url.encode(b)
        default: return "…"
        }
    }

    /// "30 min", "1 h", "1 h 30 min".
    public static func minutes(_ seconds: Double) -> String {
        guard let m = whole((seconds / 60).rounded()) else { return "?" }
        if m < 60 { return "\(max(1, m))\u{00A0}min" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h)\u{00A0}h" : "\(h)\u{00A0}h \(rest)\u{00A0}min"
    }

    // MARK: Time

    /// "1 day", "7 days", "30 days", "1 year".
    public static func length(_ ms: Int64) -> String {
        let days = Int((Double(ms) / 86_400_000).rounded())
        if days == 365 { return text("1 year") }
        return days == 1 ? text("1 day") : format("%@ days", String(days))
    }

    /// "Until 15 Nov", or "Ends today 18:00" when it ends within a day.
    public static func until(_ ms: Int64, nowMs: Double, zone: TimeZone = .current) -> String {
        if Double(ms) <= nowMs { return text("Ended") }
        if Double(ms) - nowMs < 86_400_000 { return format("Ends %@", AppWords.day(Double(ms), nowMs: nowMs, zone: zone)) }
        return format("Until %@", dayOnly(ms, nowMs: nowMs, zone: zone))
    }

    /// "15 Nov", or "17 Oct 2027" when the end is in another year or more
    /// than about five months off, so a year-long grant never reads as today.
    static func dayOnly(_ ms: Int64, nowMs: Double, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.day, .month, .year], from: Date(timeIntervalSince1970: Double(ms) / 1000))
        let day = "\(c.day ?? 1) \(AppWords.text(AppWords.monthLabels[((c.month ?? 1) + 11) % 12]))"
        let thisYear = cal.component(.year, from: Date(timeIntervalSince1970: nowMs / 1000))
        let far = Double(ms) - nowMs > 150 * 86_400_000
        guard let year = c.year, far || year != thisYear else { return day }
        return "\(day) \(year)"
    }

    /// "Never used" or "Last used today 14:03".
    public static func lastUsed(_ ms: Int64, nowMs: Double, zone: TimeZone = .current) -> String {
        ms <= 0 ? text("Never used") : format("Last used %@", AppWords.day(Double(ms), nowMs: nowMs, zone: zone))
    }

    /// The end as a value under "Ends": "8 Nov", "today 18:00" or "Ended".
    public static func ends(_ ms: Int64, nowMs: Double, zone: TimeZone = .current) -> String {
        if Double(ms) <= nowMs { return text("Ended") }
        if Double(ms) - nowMs < 86_400_000 { return AppWords.day(Double(ms), nowMs: nowMs, zone: zone) }
        return dayOnly(ms, nowMs: nowMs, zone: zone)
    }

    /// The last call as a value under "Last used": "today 08:12" or "Never".
    public static func lastCall(_ ms: Int64, nowMs: Double, zone: TimeZone = .current) -> String {
        ms <= 0 ? text("Never") : AppWords.day(Double(ms), nowMs: nowMs, zone: zone)
    }

    /// Where it was approved, as a value under "Approved".
    public static func approvedWhere(_ row: AgentRow, me: String) -> String {
        if row.approvedBy == "lan" { return text("On the box's page") }
        let id = row.approvedBy.hasPrefix("app:") ? String(row.approvedBy.dropFirst(4)) : row.approvedBy
        return id == me ? text("On this phone") : format("On phone %@", id)
    }

    // MARK: The audit log

    /// Who did it, by name where this phone knows one.
    public static func actor(_ row: AuditRow, me: String, agents: [AgentRow]) -> String {
        let (kind, id) = split(row.actor)
        switch kind {
        case "agent": return agents.first { $0.id == id }.map(name) ?? format("Assistant %@", clean(id))
        case "app": return id == me ? text("This phone") : format("Phone %@", id)
        case "lan": return id.isEmpty ? text("The box's page") : format("The box's page, %@", id)
        case "box": return text("The box")
        default: return row.actor
        }
    }

    /// The person at Sourceful behind a support call, as FTW Cloud named
    /// them. The box cannot check it, and the line says so.
    public static func by(_ row: AuditRow) -> String? {
        guard !row.by.isEmpty else { return nil }
        let (kind, raw) = split(row.by)
        let id = clean(raw)
        let who = kind == "bot" ? format("%@ (a Sourceful tool)", id) : id
        return format("%@, named by FTW Cloud", who)
    }

    /// What was done, in words, with how many times for folded reads.
    public static func what(_ row: AuditRow) -> String {
        let base = auditWords[row.what].map(text) ?? (Contract.opDescs[row.what] != nil ? op(row.what) : row.what)
        return row.count > 1 ? "\(base) ×\(row.count)" : base
    }

    /// Nil for a call that went through; otherwise what the box said.
    public static func result(_ row: AuditRow) -> String? {
        switch row.result {
        case "", "ok", "approved": return nil
        case "declined": return text("Declined")
        default: return format("Refused (%@)", row.result)
        }
    }

    static let auditWords: [String: String] = [
        "agent.add": "Granted access",
        "agent.widen": "Changed access",
        "agent.revoke": "Removed access",
        "agent.list": "Read who has access",
        "agent.request": "Asked for a change",
        "agent.request.run": "Ran an approved change",
        "agent.confirm": "Answered a request",
        "approval.key.set": "Set an approval key",
        "audit.get": "Read the activity",
        "session": "Session ended",
        "hello": "Connected",
        "cmd": "Sent a command",
        "live.get": "Read live readings",
        "loadpoints.get": "Read the chargers",
        "cars.get": "Read the cars",
        "plan.get": "Read the plan",
        "price.get": "Read prices",
        "hist.query": "Read history",
        "health.get": "Read the health summary",
        "drivers.get": "Read the devices' state",
        "events.get": "Read events",
        "logs.get": "Read the log",
        "config.get": "Read the settings",
        "diag.run": "Ran a check",
    ]

    static func split(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: ":") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    // MARK: Refusals

    /// What happens now, for anything the approval path can throw. Nil for
    /// a Face ID the person cancelled: they know.
    public static func help(_ error: Error) -> String? {
        switch error {
        case is ApprovalCancelled:
            return nil
        case is ApprovalLocked:
            return format("%@ is locked after too many tries. Unlock the phone with its passcode, then try again.", biometry)
        case is ApprovalSigningFailed:
            return text("Signing on this phone didn't work. Nothing was sent.")
        case is ApprovalKeyNotKept:
            return text("This phone couldn't keep its approval key. Nothing was sent.")
        case is ApprovalKeyLost:
            return format("The approval key on this phone stopped working when %@ changed. Replace it on your box's page with the house password.", biometry)
        case let e as OfferError:
            return offer(e)
        case let r as BoxRefusal:
            return refusal(r.detail)
        case let e as HelpfulError:
            return e.help
        case is SessionError:
            return text("Your box didn't answer. Nothing has changed. Try again when the home is live.")
        default:
            return text("That didn't work. Nothing on your box has changed.")
        }
    }

    public static func offer(_ e: OfferError) -> String {
        switch e {
        case .noPinnedKey: return text("This version of the app can't check offers from FTW Cloud yet.")
        case .unsigned: return text("This offer isn't signed by FTW Cloud. Nothing was granted.")
        case .expired: return text("This offer has run out. Start again on the page that showed it.")
        case .malformed: return text("This isn't an offer this app can read. Nothing was granted.")
        case .notFromSourceful: return text("This offer claims to come from Sourceful but comes from someone else. Nothing was granted.")
        case .strangeHost: return text("This offer names its client in letters that could imitate another address. Nothing was granted.")
        case .used: return text("This offer has been answered already. Start again on the page that showed it.")
        case .unknownHome: return text("This offer is for a home this phone doesn't have.")
        case .wrongCode: return text("That isn't the code on the page. Check it and type it again.")
        case .notFound: return text("FTW Cloud has no offer under that code. It may have been used or run out.")
        case .unreachable: return text("FTW Cloud couldn't be reached. Try again in a moment.")
        }
    }

    static func refusal(_ e: ErrorMsg) -> String {
        switch e.code {
        case "E_SCOPE_DENIED": return text("Only an owner of this home can do that.")
        case "E_BAD_SIGNATURE":
            if e.args["field"]?.string == "prevSig" {
                return text("Your box holds an older approval key for this phone. Replace it on your box's page with the house password.")
            }
            return text("Your box didn't accept the approval. Nothing has changed.")
        case "E_NO_APPROVAL_KEY": return text("Your box has no approval key for this phone yet. Try again.")
        case "E_CLOCK_SKEW": return text("This phone's clock is far from your box's. Set the time automatically and try again.")
        case "E_UNAVAILABLE":
            if e.args["subsystem"]?.string == "clock" {
                return text("Your box doesn't know the time yet, so it lets no assistant in. It will once it is online.")
            }
            return text("Your box is busy. Try again in a moment.")
        case "E_CAP_EXCEEDED":
            if e.args["cap"]?.string == "agents" { return text("Your box already lets 16 assistants in. Remove one first.") }
            return text("That is more than your box allows. Choose less.")
        case "E_NOT_FOUND": return text("That is no longer on your box.")
        case "E_CONFLICT": return text("Someone changed this meanwhile. Look again and try once more.")
        case "E_OP_NOT_GRANTED": return text("It may not ask for that.")
        case "E_UNKNOWN_OP":
            if e.args["field"]?.string == "key" { return text("Your box already has this assistant.") }
            return text("Your box can't do that yet. It may need an update.")
        default: return format("Your box said no (%@). Nothing has changed.", e.code)
        }
    }

    // MARK: Swedish

    static let sv: [String: String] = [
        // Who
        "Sourceful support": "Sourceful support",
        "Assistant %@": "Assistent %@",
        "Assistant at %@": "Assistent på %@",
        "The name it gives mentions Sourceful or FTW, so it is not shown.": "Namnet den ger nämner Sourceful eller FTW och visas därför inte.",
        "I started this myself and trust %@.": "Jag började själv och litar på %@.",
        "With control it may": "Med styrning får den",
        "Add it again from its page to let it control.": "Lägg till den igen från dess sida för att låta den styra.",
        "This request has something this app can't show you, so it can only be declined.":
            "Begäran innehåller något som appen inte kan visa, så den kan bara avböjas.",
        "%@ is locked after too many tries. Unlock the phone with its passcode, then try again.":
            "%@ är låst efter för många försök. Lås upp telefonen med koden och försök igen.",
        "Signing on this phone didn't work. Nothing was sent.": "Signeringen på telefonen gick inte. Inget skickades.",
        "This phone couldn't keep its approval key. Nothing was sent.": "Telefonen kunde inte spara sin godkännandenyckel. Inget skickades.",
        "Let %@ from %@ reach your home": "Låt %@ från %@ nå ditt hem",
        "Change what %@ from %@ may do": "Ändra vad %@ från %@ får göra",
        "Let %@ from %@ make this change": "Låt %@ från %@ göra ändringen",
        "Access": "Åtkomst",
        "Assistants and support": "Assistenter och support",
        "Assistants": "Assistenter",
        "Get help": "Få hjälp",
        "Activity": "Aktivitet",
        "Waiting for you": "Väntar på dig",
        "%@ waiting": "%@ väntar",
        "No assistant can reach your home.": "Ingen assistent når ditt hem.",
        "Add an assistant": "Lägg till en assistent",
        "Assistants such as Claude or ChatGPT reach your home through FTW Cloud, with what you let them. Your box checks every call.":
            "Assistenter som Claude eller ChatGPT når ditt hem genom FTW Cloud, med det du låter dem. Boxen kontrollerar varje anrop.",
        "Verified by FTW Cloud": "Verifierad av FTW Cloud",
        "Not verified": "Inte verifierad",
        "FTW Cloud doesn't know this client. Check that the address is the one you expect.":
            "FTW Cloud känner inte den här klienten. Kontrollera att adressen är den du väntar dig.",
        "Calls itself %@": "Kallar sig %@",
        "Home": "Hem",
        // Rights
        "It may": "Den får",
        "May": "Får",
        "Reads": "Läser",
        "Reads and controls": "Läser och styr",
        "Reads and setup": "Läser och konfigurerar",
        "Reads, setup and control": "Läser, konfigurerar och styr",
        "Read full diagnostics, source, logs and backups, which can contain saved credentials": "Läsa full diagnostik, källkod, loggar och säkerhetskopior som kan innehålla sparade inloggningsuppgifter",
        "Save confirmed setup and restart to apply it when you confirm": "Spara bekräftad konfiguration och starta om när du godkänner det",
        "Allow setup": "Tillåt konfigurering",
        "Off until you choose it. This includes equipment names and connection settings. Review and confirm the exact draft before it saves, and confirm any restart separately. Equipment settings can affect operation; the box keeps its safety checks.": "Av tills du väljer det. Det omfattar utrustningens namn och anslutningsinställningar. Granska och bekräfta det exakta utkastet före sparning och godkänn varje omstart för sig. Utrustningens inställningar kan påverka driften; boxens säkerhetskontroller gäller.",
        "Short control actions are off.": "Tillfälliga styråtgärder är avstängda.",

        "Control": "Styra",
        "Also let it control": "Låt den också styra",
        "See live readings": "Se mätvärden just nu",
        "See history": "Se historik",
        "See the plan and prices": "Se planen och priserna",
        "See how the box and its devices are doing": "Se hur boxen och enheterna mår",
        "See events": "Se händelser",
        "Read the box's log, with names taken out": "Läsa boxens logg, utan namn",
        "Read the settings, with names and secrets taken out": "Läsa inställningarna, utan namn och hemligheter",
        "Run checks that change nothing": "Köra kontroller som inte ändrar något",
        "Charge the car for a short while": "Ladda bilen en kort stund",
        "Ask you for lasting changes": "Be dig om varaktiga ändringar",
        "It may charge the car for up to %@ at a time, at most %@.": "Den får ladda bilen i högst %@ åt gången, med högst %@.",
        "Lasting changes, such as the mode or a goal, wait for your %@.": "Varaktiga ändringar, som läget eller ett mål, väntar på ditt %@.",
        "Off: it reads and changes nothing.": "Av: den läser och ändrar ingenting.",
        "For": "Hur länge",
        "1 day": "1 dag",
        "1 year": "1 år",
        "%@ days": "%@ dagar",
        "Until %@": "Till %@",
        "Ends %@": "Slutar %@",
        "Ended": "Slutat",
        "Never used": "Aldrig använd",
        "Last used %@": "Senast använd %@",
        "Never": "Aldrig",
        "On the box's page": "På boxens sida",
        "On this phone": "På den här telefonen",
        "On phone %@": "På telefon %@",
        "Choose at least one thing it may do.": "Välj minst en sak den får göra.",
        "Ticket %@": "Ärende %@",
        // Offer
        "Type the code on the page": "Skriv koden från sidan",
        "The page that asked for access shows a code. Type it here only if you started this yourself, on a page you trust.":
            "Sidan som bad om åtkomst visar en kod. Skriv den här bara om du själv började, på en sida du litar på.",
        "Continue": "Fortsätt",
        "Cancel": "Avbryt",
        "Approve with %@": "Godkänn med %@",
        "Let %@ reach your home": "Låt %@ nå ditt hem",
        "%@ can now reach your home.": "%@ når nu ditt hem.",
        "Your box checks every call, and you can remove the access at any time.":
            "Boxen kontrollerar varje anrop, och du kan ta bort åtkomsten när du vill.",
        "Done": "Klar",
        "Checking the offer": "Kontrollerar erbjudandet",
        "Code on the page": "Koden på sidan",
        // One grant
        "Save with %@": "Spara med %@",
        "Remove access": "Ta bort åtkomst",
        "Change what %@ may do": "Ändra vad %@ får göra",
        "Approved": "Godkänd",
        "Last used": "Senast använd",
        "Ends": "Slutar",
        "Renew for": "Förnya i",
        // Requests
        "%@ asks to": "%@ ber om att",
        "In its own words": "Med egna ord",
        "Asked %@": "Frågade %@",
        "Approve": "Godkänn",
        "Decline": "Avböj",
        "Let %@ make this change": "Låt %@ göra ändringen",
        "Approving runs it on your box now, as if you had made the change yourself.":
            "Godkänner du körs ändringen på boxen nu, som om du hade gjort den själv.",
        "Charger": "Laddare",
        "Car": "Bil",
        "Operating mode": "Driftläge",
        "How cautious the plan is": "Hur försiktig planen är",
        "Whether the battery may sell to the grid": "Om batteriet får sälja till nätet",
        "Charging power": "Laddeffekt",
        "For how long": "Hur länge",
        "Phases": "Faser",
        "Stop the agent's own hold": "Avsluta assistentens egen laddning",
        "The car's charge level": "Bilens laddnivå",
        "Charge from solar only": "Ladda bara med sol",
        "The level to reach": "Nivå att nå",
        "Ready by, in minutes after midnight": "Klar till",
        "Weekdays": "Veckodagar",
        "Charge on to the car's own limit": "Ladda vidare till bilens egen gräns",
        "Remove the goal": "Ta bort målet",
        "Yes": "Ja",
        "No": "Nej",
        "Not set": "Inte valt",
        "Automatic": "Automatiskt",
        "One phase": "En fas",
        "Three phases": "Tre faser",
        "Change how the home is run": "Ändra hur hemmet körs",
        "Change the plan's settings": "Ändra planens inställningar",
        "Charge the car now": "Ladda bilen nu",
        "Correct the car's level": "Rätta bilens nivå",
        "Charge the car from solar only": "Ladda bilen bara med sol",
        "Change when and how far the car charges": "Ändra när och hur långt bilen laddar",
        "Set the car's level": "Ange bilens nivå",
        "Waits %@": "Väntar till %@",
        // Activity
        "This phone": "Den här telefonen",
        "Phone %@": "Telefon %@",
        "The box's page": "Boxens sida",
        "The box's page, %@": "Boxens sida, %@",
        "The box": "Boxen",
        "%@ (a Sourceful tool)": "%@ (ett verktyg hos Sourceful)",
        "%@, named by FTW Cloud": "%@, enligt FTW Cloud",
        "Declined": "Avböjd",
        "Refused (%@)": "Nekad (%@)",
        "Load older": "Visa äldre",
        "Nothing has happened yet.": "Inget har hänt än.",
        "Granted access": "Gav åtkomst",
        "Changed access": "Ändrade åtkomst",
        "Removed access": "Tog bort åtkomst",
        "Read who has access": "Läste vem som har åtkomst",
        "Asked for a change": "Bad om en ändring",
        "Ran an approved change": "Körde en godkänd ändring",
        "Answered a request": "Svarade på en begäran",
        "Set an approval key": "Satte en godkännandenyckel",
        "Read the activity": "Läste aktiviteten",
        "Session ended": "Sessionen slutade",
        "Connected": "Anslöt",
        "Sent a command": "Skickade ett kommando",
        "Read live readings": "Läste mätvärden",
        "Read the chargers": "Läste laddarna",
        "Read the cars": "Läste bilarna",
        "Read the plan": "Läste planen",
        "Read prices": "Läste priser",
        "Read history": "Läste historik",
        "Read the health summary": "Läste hälsan",
        "Read the devices' state": "Läste enheternas läge",
        "Read events": "Läste händelser",
        "Read the log": "Läste loggen",
        "Read the settings": "Läste inställningarna",
        "Ran a check": "Körde en kontroll",
        // The key
        "Approvals on this phone use %@.": "Godkännanden på den här telefonen använder %@.",
        "This phone makes its approval key the first time you approve, under the same %@.":
            "Telefonen gör sin godkännandenyckel första gången du godkänner, med samma %@.",
        "Replace the approval key": "Byt godkännandenyckel",
        "Replace the approval key on this phone": "Byt godkännandenyckeln på den här telefonen",
        "The approval key on this phone stopped working when %@ changed. Replace it on your box's page with the house password.":
            "Godkännandenyckeln på telefonen slutade fungera när %@ ändrades. Byt den på boxens sida med husets lösenord.",
        "This phone can't approve on its own. Use your box's page.": "Telefonen kan inte godkänna själv. Använd boxens sida.",
        // Get help
        "Describe the problem": "Beskriv problemet",
        "What happened, and when?": "Vad hände, och när?",
        "Let Sourceful look": "Låt Sourceful titta",
        "Your words go to Sourceful's help desk with the ticket. Your box never sees them.":
            "Orden går till Sourcefuls helpdesk med ärendet. Boxen ser dem aldrig.",
        "Next you see what Sourceful asks to do, and approve it with %@.":
            "Sedan ser du vad Sourceful ber om att få göra, och godkänner med %@.",
        "Every call names the person at Sourceful who made it. You can remove the access at any time, and it ends when the ticket closes.":
            "Varje anrop säger vem hos Sourceful som gjorde det. Du kan ta bort åtkomsten när du vill, och den slutar när ärendet stängs.",
        "Sourceful can't open a ticket from the app yet.": "Sourceful kan inte öppna ett ärende från appen än.",
        // Refusals
        "Set up %@ on this phone to approve from it, or approve on your box's page.": "Ställ in %@ på telefonen för att godkänna från den, eller godkänn på boxens sida.",
        "This version of the app can't check offers from FTW Cloud yet.": "Den här versionen av appen kan inte kontrollera erbjudanden från FTW Cloud än.",
        "This offer isn't signed by FTW Cloud. Nothing was granted.": "Erbjudandet är inte signerat av FTW Cloud. Inget har getts.",
        "This offer has run out. Start again on the page that showed it.": "Erbjudandet har gått ut. Börja om på sidan som visade det.",
        "This isn't an offer this app can read. Nothing was granted.": "Det här är inget erbjudande appen kan läsa. Inget har getts.",
        "This offer claims to come from Sourceful but comes from someone else. Nothing was granted.":
            "Erbjudandet säger sig komma från Sourceful men kommer från någon annan. Inget har getts.",
        "This offer names its client in letters that could imitate another address. Nothing was granted.":
            "Erbjudandet skriver klientens adress med tecken som kan härma en annan adress. Inget har getts.",
        "This offer has been answered already. Start again on the page that showed it.":
            "Erbjudandet är redan besvarat. Börja om på sidan som visade det.",
        "This offer is for a home this phone doesn't have.": "Erbjudandet gäller ett hem som telefonen inte har.",
        "That isn't the code on the page. Check it and type it again.": "Det är inte koden på sidan. Kontrollera och skriv den igen.",
        "FTW Cloud has no offer under that code. It may have been used or run out.": "FTW Cloud har inget erbjudande med den koden. Den kan vara använd eller ha gått ut.",
        "FTW Cloud couldn't be reached. Try again in a moment.": "FTW Cloud gick inte att nå. Försök igen om en stund.",
        "Only an owner of this home can do that.": "Bara en ägare av hemmet kan göra det.",
        "Your box holds an older approval key for this phone. Replace it on your box's page with the house password.":
            "Boxen har en äldre godkännandenyckel för telefonen. Byt den på boxens sida med husets lösenord.",
        "Your box didn't accept the approval. Nothing has changed.": "Boxen tog inte emot godkännandet. Inget har ändrats.",
        "Your box has no approval key for this phone yet. Try again.": "Boxen har ingen godkännandenyckel för telefonen än. Försök igen.",
        "This phone's clock is far from your box's. Set the time automatically and try again.": "Telefonens klocka går långt från boxens. Ställ tiden automatiskt och försök igen.",
        "Your box doesn't know the time yet, so it lets no assistant in. It will once it is online.":
            "Boxen vet inte vad klockan är än, så den släpper inte in någon assistent. Det gör den när den är online.",
        "Your box is busy. Try again in a moment.": "Boxen är upptagen. Försök igen om en stund.",
        "Your box already lets 16 assistants in. Remove one first.": "Boxen släpper redan in 16 assistenter. Ta bort en först.",
        "That is more than your box allows. Choose less.": "Det är mer än boxen tillåter. Välj mindre.",
        "That is no longer on your box.": "Det finns inte längre på boxen.",
        "Someone changed this meanwhile. Look again and try once more.": "Någon ändrade det här under tiden. Titta igen och försök en gång till.",
        "It may not ask for that.": "Den får inte be om det.",
        "Your box already has this assistant.": "Boxen har redan den här assistenten.",
        "Your box can't do that yet. It may need an update.": "Boxen kan inte göra det än. Den kan behöva en uppdatering.",
        "Your box said no (%@). Nothing has changed.": "Boxen sa nej (%@). Inget har ändrats.",
        "Your box didn't answer. Nothing has changed. Try again when the home is live.": "Boxen svarade inte. Inget har ändrats. Försök igen när hemmet är live.",
        "That didn't work. Nothing on your box has changed.": "Det gick inte. Inget på din box har ändrats.",
    ]
}
