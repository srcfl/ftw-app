import Foundation

/// The words of Source & licenses and of removing this phone, in English or
/// Swedish as the phone prefers. Keyed by the English, so a missing entry
/// shows English rather than nothing; a test reads the views and fails on
/// any sentence without a Swedish entry.
public enum AboutWords {
    public enum Language: String, Sendable {
        case en, sv

        /// The phone's choice among the two the app speaks.
        public static var preferred: Language {
            Bundle.preferredLocalizations(from: ["en", "sv"]).first == "sv" ? .sv : .en
        }
    }

    @TaskLocal public static var language: Language = .preferred

    public static func text(_ en: String) -> String {
        language == .sv ? (sv[en] ?? en) : en
    }

    /// `%@` in order, replaced with ready text.
    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for arg in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: arg)
        }
        return out
    }

    static let sv: [String: String] = [
        // Source & licenses
        "Source & licenses": "Källkod och licenser",
        "Done": "Klar",
        "This version": "Den här versionen",
        "Version": "Version",
        "Build": "Bygge",
        "Commit": "Commit",
        "Local build": "Lokalt bygge",
        "Source code": "Källkod",
        "Source code of this version": "Källkoden till den här versionen",
        "Source code on GitHub": "Källkoden på GitHub",
        "License at this commit": "Licensen i den här commiten",
        "License on GitHub": "Licensen på GitHub",
        "FTW is free software. You may run, study, change and share it under the GNU AGPL v3 with the two additional permissions in LICENSE. The link gives the complete source of this exact version, at no charge.":
            "FTW är fri programvara. Du får köra, studera, ändra och dela den enligt GNU AGPL v3 med de två extra tillstånden i LICENSE. Länken ger hela källkoden till exakt den här versionen, utan kostnad.",
        "Built from uncommitted changes on top of %@. The links go to the repository, which does not hold these changes.":
            "Byggd från ändringar som inte är incheckade, ovanpå %@. Länkarna går till repot, som inte har de här ändringarna.",
        "Built without a known commit. The links go to the repository, which may not hold this exact code.":
            "Byggd utan känd commit. Länkarna går till repot, som kanske inte har exakt den här koden.",
        "Licenses": "Licenser",
        "License": "Licens",
        "Notices": "Notiser",
        "Licensing in plain words": "Licensen i klartext",
        "Third-party code": "Tredjepartskod",
        "None. FTW uses only Apple's own frameworks.": "Ingen. FTW använder bara Apples egna ramverk.",
        "© 2026 Sourceful Labs AB and contributors.": "© 2026 Sourceful Labs AB och bidragsgivare.",
        "There is no warranty, to the extent the law allows.": "Det finns ingen garanti, så långt lagen tillåter.",
        "This text is missing from this build.": "Texten saknas i det här bygget.",
        "Privacy": "Integritet",
        "Privacy policy": "Integritetspolicy",
        "Support": "Support",
        "Privacy and support": "Integritet och support",
        "FTW collects nothing about you. Readings and commands travel encrypted between this phone and your box, and Sourceful cannot read them.":
            "FTW samlar inte in något om dig. Mätvärden och kommandon går krypterade mellan telefonen och boxen, och Sourceful kan inte läsa dem.",

        // Removing this phone
        "This phone": "Den här telefonen",
        "Remove this phone": "Ta bort den här telefonen",
        "This deletes what FTW keeps on this phone: the key to your home, the pairing, the saved readings and what the widgets show. Your box and everything on it stay as they are.":
            "Det här raderar det FTW sparar på telefonen: nyckeln till ditt hem, parkopplingen, sparade mätvärden och det widgetarna visar. Boxen och allt på den blir kvar som det är.",
        "FTW has no account with Sourceful. Your box keeps a row for this phone until you remove it there.":
            "FTW har inget konto hos Sourceful. Boxen har kvar en rad för telefonen tills du tar bort den där.",
        "On your box": "På boxen",
        "Your box calls this phone": "Boxen kallar telefonen",
        "Open your box's local dashboard while on your home network.": "Öppna boxens lokala sida medan du är på hemnätverket.",
        "Go to Settings → FTW app.": "Gå till Settings → FTW app.",
        "Choose Remove next to %@.": "Välj Remove bredvid %@.",
        "Once it is gone there, the box no longer lets this phone in. Do it before or after the step below.":
            "När den är borta där släpper boxen inte längre in telefonen. Gör det före eller efter steget nedan.",
        "On this phone": "På telefonen",
        "Remove from this phone": "Ta bort från telefonen",
        "If you made a passkey for FTW, it stays in the Passwords app, where you can delete it. Keep it if another device of yours still uses FTW.":
            "Om du skapade en lösennyckel för FTW finns den kvar i appen Lösenord, där du kan radera den. Behåll den om en annan av dina enheter fortfarande använder FTW.",
        "Remove this phone?": "Ta bort den här telefonen?",
        "FTW forgets your home on this phone. To come back, scan a new pairing QR from your box.":
            "FTW glömmer ditt hem på telefonen. För att komma tillbaka skannar du en ny QR-kod för parkoppling från boxen.",
        "Remove": "Ta bort",
        "Cancel": "Avbryt",
    ]
}
