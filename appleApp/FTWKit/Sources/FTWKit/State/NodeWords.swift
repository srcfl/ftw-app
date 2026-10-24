import Foundation

/// The words of Now's nodes and the views they open (live, history, plan
/// and mode), in English or Swedish as the phone prefers. Keyed by the
/// English, so a missing entry shows English rather than nothing; a test
/// reads the views and fails on any sentence without a Swedish entry.
///
/// It follows `AppWords.language`, so the app speaks one language, and
/// falls back to `AppWords` for the sentences the rest of the app shares.
public enum NodeWords {
    public static func text(_ en: String) -> String {
        AppWords.language == .sv ? (sv[en] ?? AppWords.text(en)) : en
    }

    /// `%@` in order, or `%1$@` by position, replaced with ready text.
    public static func format(_ en: String, _ args: String...) -> String {
        var out = text(en)
        for (i, a) in args.enumerated() { out = out.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    public static func timelineMaterial(sampleMs: Double, planned: Bool) -> String {
        let minutes = max(1, Int((sampleMs / 60_000).rounded()))
        let history = minutes.isMultiple(of: 60)
            ? format("History: closed %@-hour means", "\(minutes / 60)")
            : format("History: closed %@-minute means", "\(minutes)")
        return history + " · " + text("live: source readings") + " · "
            + text(planned ? "future bars: plan" : "dashed: forecast")
    }

    static let sv: [String: String] = [
        "History and live readings": "Historik och livevärden",
        "Swipe up or down to move through time. Actions change the zoom.": "Svep uppåt eller nedåt för att flytta tiden. Åtgärder ändrar zoom.",
        "Zoom in": "Zooma in",
        "Zoom out": "Zooma ut",
        "Back to now": "Tillbaka till nu",
        "Drag through time · pinch to zoom · hold to read": "Dra genom tiden · nyp för att zooma · håll för att läsa",
        "History: closed %@-minute means": "Historik: avslutade %@-minutersmedel",
        "History: closed %@-hour means": "Historik: avslutade %@-timmarsmedel",
        "live: source readings": "live: källvärden",
        "future bars: plan": "framtida staplar: plan",
        "dashed: forecast": "streckat: prognos",
        "source reading": "källvärde",
        "saved reading": "sparat värde",
        "interval mean": "intervallmedel",
        "forecast": "prognos",
        "planned": "planerat",
        "No plan or forecast for this time.": "Ingen plan eller prognos för den här tiden.",
        "Fetching history…": "Hämtar historik…",
        "No recorded history in this window.": "Ingen sparad historik i det här tidsfönstret.",
        "No recorded energy in this window.": "Ingen sparad energi i det här tidsfönstret.",
        "Plan and forecast · not measured energy": "Plan och prognos · inte uppmätt energi",
        "Recorded in view": "Sparat i perioden",
        "Waiting for history": "Väntar på historik",
        "last interval filling": "senaste intervallet pågår",
        // Modes, by the registry's keys
        "Plan": "Plan",
        "Plan, selling too": "Plan, säljer också",
        "Plan for own use": "Plan för egen förbrukning",
        "Plan for cheap hours": "Plan för billiga timmar",
        "Own use": "Egen förbrukning",
        "Peak shaving": "Kapa toppar",
        "Charge the battery": "Ladda batteriet",
        "Stop batteries": "Stoppa batterierna",
        "Charges when power is cheap or the sun shines, covers the home when it is dear, and never sells from the battery.": "Laddar när elen är billig eller solen skiner, täcker hemmet när den är dyr och säljer aldrig från batteriet.",
        "Like Plan, and also sells from the battery when the price is high enough.": "Som Plan, och säljer också från batteriet när priset är tillräckligt högt.",
        "No plan. The battery takes spare solar and covers the home as it happens.": "Ingen plan. Batteriet tar överskott från solen och täcker hemmet allt eftersom.",
        "No plan. The battery holds what the home buys under the peak limit.": "Ingen plan. Batteriet håller köpet från elnätet under effekttaket.",
        "No plan. Charges the battery full whatever the price.": "Ingen plan. Laddar batteriet fullt oavsett pris.",
        "No plan. Every battery holds at 0 W. Fuse protection and car charging carry on.": "Ingen plan. Alla batterier står still på 0 W. Säkringsskyddet och billaddningen fortsätter.",

        // Live, history and the plan
        "Live": "Live",
        "Live · last 5 min": "Live · senaste 5 min",
        // The node view's footer and live range line.
        "LIVE": "LIVE",
        "CALCULATED": "BERÄKNAD",
        "NO READING YET": "INGEN MÄTNING ÄN",
        "NOT LIVE": "INTE LIVE",
        "AS OF %@": "PER %@",
        "VIA RELAY": "VIA RELÄ",
        "VIA DIRECT LINK": "VIA DIREKTLÄNK",
        "VIA FTW CLOUD": "VIA FTW CLOUD",
        "ENCRYPTED VIA FTW CLOUD": "KRYPTERAT VIA FTW CLOUD",
        "SAVED ON THIS PHONE": "SPARAD PÅ TELEFONEN",
        "NOT CONNECTED": "INTE ANSLUTEN",
        // The grid's phases against the main fuse.
        "PHASES": "FASER",
        "PHASES · FUSE %@": "FASER · SÄKRING %@",
        "nearest the fuse": "närmast säkringen",
        "The phases are not live.": "Faserna är inte live.",
        "READS EVERY %@ S": "LÄSER VAR %@ S",
        "LAST 5 MIN": "SENASTE 5 MIN",
        "LIVE · LAST 5 MIN": "LIVE · SENASTE 5 MIN",
        "5 min: made %@": "5 min: producerat %@",
        "5 min: charged %@ · gave %@": "5 min: laddat %@ · gett %@",
        "5 min: used %@": "5 min: använt %@",
        "5 min: bought %@ · sold %@": "5 min: köpt %@ · sålt %@",
        "5 min: charged %@": "5 min: laddat %@",
        "earns ≈ %@": "tjänar ≈ %@",
        "%@ of forecast": "%@ av prognosen",
        "%@ expected": "%@ väntas",
        "sun from about %@": "sol från cirka %@",
        "Live, the last five minutes": "Live, de senaste fem minuterna",
        "calculated": "beräknad",
        "Play as sound": "Spela som ljud",
        "%@-minute means": "%@-minutersmedel",
        "Close": "Stäng",
        "Enlarge the chart": "Förstora diagrammet",
        "FETCHING…": "HÄMTAS …",
        "NOW": "NU",
        "Drawing as readings arrive…": "Ritas när mätningarna kommer …",
        "No live readings while your box is out of reach.": "Inga livevärden medan boxen inte går att nå.",
        "No reading yet": "Ingen mätning än",
        "Not live, %@": "Inte live, %@",
        "Not reporting, %@": "Rapporterar inte, %@",
        "Saved on this phone, %@": "Sparat i telefonen, %@",
        "Split read at %@": "Fördelningen läst %@",
        "Your box sends no reading for this.": "Boxen skickar ingen mätning för det här.",
        "Period": "Period",
        "Today": "I dag",
        "Yesterday": "I går",
        // The timeline's lines and readout.
        "So far: %@": "Hittills: %@",
        "saved": "sparad",
        "plan": "plan",
        "What FTW plans or forecasts, not measured.": "Det FTW planerar eller förutser, inte uppmätt.",
        "Tomorrow": "I morgon",
        "48 h": "48 h",
        "Ahead": "Framåt",
        "Today: made %@": "I dag: producerat %@",
        "Today: charged %@ · gave %@": "I dag: laddat %@ · gett %@",
        "Today: used %@": "I dag: använt %@",
        "Today: bought %@ · sold %@": "I dag: köpt %@ · sålt %@",
        "Today: charged %@": "I dag: laddat %@",
        "48 h: made %@": "48 h: producerat %@",
        "48 h: charged %@ · gave %@": "48 h: laddat %@ · gett %@",
        "48 h: used %@": "48 h: använt %@",
        "48 h: bought %@ · sold %@": "48 h: köpt %@ · sålt %@",
        "48 h: charged %@": "48 h: laddat %@",
        "%@ not recorded": "%@ saknas",
        // History's rows: the same day without "Today:", which the tab says.
        "Made %@": "Producerat %@",
        "Charged %@ · gave %@": "Laddat %@ · gett %@",
        "Used %@": "Använt %@",
        "Bought %@ · sold %@": "Köpt %@ · sålt %@",
        "Charged %@": "Laddat %@",
        "Opens what your home saved.": "Öppnar vad hemmet har sparat.",
        "Opens this day's chart.": "Öppnar dagens diagram.",
        "Not read yet": "Inte läst än",
        "Your box keeps no history.": "Boxen sparar ingen historik.",
        "No history yet. Your box is out of reach.": "Ingen historik än. Boxen går inte att nå.",
        "Not up to date. Your box is out of reach.": "Inte uppdaterat. Boxen går inte att nå.",
        "From FTW Cloud · up to %@": "Från FTW Cloud · fram till %@",
        "Your box can't send its history right now. Still trying.": "Boxen kan inte skicka sin historik just nu. Försöker igen.",
        "Couldn't get the plan from your box. Still trying.": "Fick ingen plan från boxen. Försöker igen.",
        "Your box couldn't plan ahead just now, so it runs on safe defaults.": "Boxen kunde inte planera framåt just nu, så den kör på säkra standardval.",
        "No plan for the hours ahead yet.": "Ingen plan för de kommande timmarna än.",
        "No forecast for the hours ahead yet.": "Ingen prognos för de kommande timmarna än.",
        "Charges at up to %@ until %@, %@.": "Laddar med upp till %@ till %@, %@.",
        "Gives the home up to %@ until %@, %@.": "Ger hemmet upp till %@ till %@, %@.",
        "Rests until %@, %@.": "Vilar till %@, %@.",
        "Then charges, %@.": "Sedan laddar batteriet, %@.",
        "Then gives power, %@.": "Sedan ger batteriet ström, %@.",
        "Then rests.": "Sedan vilar batteriet.",
        "Expects to buy %@ and sell %@ over the next 12 hours.": "Räknar med att köpa %@ och sälja %@ de närmaste 12 timmarna.",
        "Expects to buy %@ over the next 12 hours.": "Räknar med att köpa %@ de närmaste 12 timmarna.",
        "Expects the sun to make %@ in the next 12 hours.": "Räknar med att solen ger %@ de närmaste 12 timmarna.",
        "No sun expected in the next 12 hours.": "Ingen sol väntas de närmaste 12 timmarna.",
        "Expects the home to use %@ in the next 12 hours.": "Räknar med att hemmet använder %@ de närmaste 12 timmarna.",
        "power is cheap": "elen är billig",
        "power is dear": "elen är dyr",
        "spare solar": "solen ger överskott",
        "holding the grid limit": "håller effekttaket",
        "keeping a reserve": "behåller en reserv",
        "selling pays": "det lönar sig att sälja",
        "nothing to gain": "inget att vinna",

        "Charges %@–%@, %@ in all.": "Laddar %@–%@, %@ totalt.",
        "No charging planned in the next 12 hours.": "Ingen laddning planerad de närmaste 12 timmarna.",

        // Price
        "Price now": "Elpris nu",
        "Prices ahead": "Priser framåt",
        "Cheapest 2 h: %@–%@ · %@": "Billigast 2 h: %@–%@ · %@",

        // The plan view
        "Opens the plan.": "Öppnar planen.",
        "Opens the price ahead.": "Öppnar elpriset framåt.",
        "Dial": "Tavla",
        "battery level": "batteriets nivå",
        "%@ with the forecast": "%@ med prognosen",
        "Lanes": "Banor",
        "Show the plan as": "Visa planen som",
        "Swipe up or down to move an hour.": "Svep uppåt eller nedåt för att flytta en timme.",
        "Battery charges": "Batteriet laddar",
        "Battery gives power": "Batteriet laddar ur",
        "Cheapest": "Billigast",
        "Reading the plan from your box…": "Läser planen från boxen …",
        "Planned by your box at %@. It plans again every quarter of an hour.": "Boxen planerade kl. %@. Den planerar om varje kvart.",
        "%@ more later": "%@ till senare",
        "up to %@": "upp till %@",
        "%@ on average": "%@ i snitt",
        "now": "nu",

        // The car
        "Charging": "Laddning",
        "Goal, level and Charge now": "Mål, nivå och Ladda nu",

        // Planning styles
        "Very careful": "Mycket försiktig",
        "Careful": "Försiktig",
        "Balanced": "Balanserad",
        "Bold": "Djärv",
        "Very bold": "Mycket djärv",
        "Plans for a poor day: much less sun and more use than forecast. Keeps the most in the battery.": "Planerar för en dålig dag: mycket mindre sol och mer förbrukning än prognosen. Sparar mest i batteriet.",
        "Plans for less sun and more use than forecast.": "Planerar för mindre sol och mer förbrukning än prognosen.",
        "Plans for a little less sun and a little more use than forecast. A good start for most homes.": "Planerar för lite mindre sol och lite mer förbrukning än prognosen. En bra start för de flesta hem.",
        "Plans close to the forecast.": "Planerar nära prognosen.",
        "Plans for a poor day.": "Planerar för en dålig dag.",
        "Plans for less sun.": "Planerar för mindre sol.",
        "Plans with a little margin.": "Planerar med lite marginal.",
        "Plans on the forecast as it is.": "Planerar efter prognosen som den är.",
        "Plans on the forecast as it is. Earns the most when it is right and costs more when it is wrong.": "Planerar efter prognosen som den är. Tjänar mest när den stämmer och kostar mer när den slår fel.",
        "Let the battery sell to the grid when it pays": "Låt batteriet sälja till elnätet när det lönar sig",
        "A manual mode runs until you choose another. FTW does not plan meanwhile.": "Ett manuellt läge gäller tills du väljer ett annat. FTW planerar inte under tiden.",
        "Your box has it. Planning again…": "Boxen har tagit emot det. Planerar om …",
        "Sending to your box…": "Skickar till boxen …",
        "The planning style is now %@.": "Planeringsstilen är nu %@.",
        "The battery may now sell when it pays.": "Batteriet får nu sälja när det lönar sig.",
        "The battery no longer sells to the grid.": "Batteriet säljer inte längre till elnätet.",

        // Nodes
        "Solar": "Sol",
        "Battery": "Batteri",
        "Home": "Hemmet",
        "Usage": "Förbrukning",
        "Grid": "Elnät",
        "Car": "Bil",
        "SOLAR": "SOL",
        "BATTERY": "BATTERI",
        "USAGE": "FÖRBRUKNING",
        "GRID": "ELNÄT",
        "CAR": "BIL",
        "making": "producerar",
        "resting": "vilar",
        "charging": "laddar",
        "discharging": "laddar ur",
        "giving power": "ger ström",
        "buying": "köper",
        "selling": "säljer",
        "balanced": "i balans",
        "idle": "vilar",
        "dark": "mörkt",
        "using": "använder",
        "%@ · home": "%@ · hemmet",
        "no reading": "ingen mätning",
        "not live": "inte live",
        "live": "live",
        "Opens live readings, history and the plan.": "Öppnar livevärden, historik och plan.",
        "%@ old": "%@ gammal",
        "Reading from %@": "Mätning från %@",

        // Mode
        "Mode": "Läge",
        // VoiceOver, for a car level FTW assumes.
        "about %@": "ungefär %@",
        "Mode: %@": "Läge: %@",
        "Change": "Byt",
        "Change mode": "Byt läge",
        "Swipe up or down to change the style.": "Svep uppåt eller nedåt för att byta stil.",
        "No goal": "Inget mål",
        "How your home is run": "Så styrs ditt hem",
        "Manual": "Manuellt",
        "Planning style": "Planeringsstil",
        "Sending %@ to your box…": "Skickar %@ till boxen …",
        "Your box has it. Switching to %@…": "Boxen har tagit emot det. Byter till %@ …",
        "Your box now runs %@.": "Boxen kör nu %@.",
        "Something else changed the mode first. Have a look and try again.": "Något annat bytte läge först. Titta efter och försök igen.",
        "Your box took it but has not confirmed it yet.": "Boxen tog emot det men har inte bekräftat än.",
        "That took too long to reach your box. Try again.": "Det tog för lång tid att nå boxen. Försök igen.",
        "Something changed at home while this was sending. Try again.": "Något ändrades hemma medan det skickades. Försök igen.",
        "Only the home's owner can change how it runs.": "Bara hemmets ägare kan ändra hur det styrs.",
        "Your box is starting. Give it a minute.": "Boxen startar. Vänta en minut.",
        "Your box cannot do this yet. It may need an update.": "Boxen kan inte det här än. Den kan behöva en uppdatering.",
        "Your box did not change the mode. Nothing else changed.": "Boxen bytte inte läge. Inget annat ändrades.",
        "That did not reach your box. Try again.": "Det nådde inte boxen. Försök igen.",
        "Not connected to your box right now. Try again when the connection is back.": "Inte ansluten till boxen just nu. Försök igen när anslutningen är tillbaka.",
        "That did not go through. Try again.": "Det gick inte igenom. Försök igen.",
        "Waiting for the connection…": "Väntar på anslutningen …",
        "Asked for %@. Your box has not confirmed it.": "Bad om %@. Boxen har inte bekräftat det.",
        "selling to the grid": "försäljning till nätet",
        "not selling to the grid": "ingen försäljning till nätet",
        "Not confirmed": "Inte bekräftat",
        "Each choice goes to your box at once.": "Varje val går till boxen direkt.",
        "Waiting for your box. You can choose when it answers.": "Väntar på boxen. Du kan välja när den svarar.",
        "Try again": "Försök igen",
        "This phone is offline": "Telefonen är offline",
        // What a chart says under the finger.
        "fetching…": "hämtas …",
        "no data": "ingen data",
        "%@ so far": "%@ hittills",
        "↑ %@ ↓ %@ so far": "↑ %@ ↓ %@ hittills",
        "↑ %@ ↓ %@": "↑ %@ ↓ %@",
        "average %@": "i snitt %@",
        "forecast %@": "prognos %@",
        "nothing planned": "inget planerat",
        "charged %@": "laddade %@",
        "Electricity price": "Elpris",
        "No prices ahead yet.": "Inga priser framåt än.",
        "Reading the prices from your box…": "Läser priserna från boxen …",
        "Cheapest %@ · %@ on average": "Billigast %@ · %@ i snitt",
        "avg %@": "snitt %@",
        "Nothing planned then": "Inget planerat då",
        "Now · %@": "Nu · %@",
        "not charging": "laddar inte",
        "Time": "Tid",
        "Power": "Effekt",
        // Pairing. The box's own dashboard is in English, so its labels
        // (Settings → FTW app, Show pairing code) stay as it shows them.
        "Scan the pairing QR": "Skanna QR-koden",
        "Securing this phone": "Skyddar telefonen",
        "Connect to a different box?": "Ansluta en annan box?",
        "Connect this box?": "Ansluta den här boxen?",
        "Get this phone back in": "Få in telefonen igen",
        "Welcome back": "Välkommen tillbaka",
        "Connect FTW": "Anslut FTW",
        "Can't see Show pairing code? Turn on Let the FTW app connect to this box, then choose Save and restart FTW in the dashboard.": "Ser du inte Show pairing code? Slå på Let the FTW app connect to this box och välj sedan Save and restart FTW i webbgränssnittet.",
        "Enter pairing code": "Ange parkod",
        "Connect": "Anslut",
        "Stay on your home Wi-Fi.": "Anslut till hemmets wifi.",
        "Box address": "Boxens adress",
        "Pairing code": "Parkod",
        "House password": "Huslösenord",
        "Connecting to your box": "Ansluter till boxen",
        "On this iPhone, open your box in Safari. In Settings → FTW app, choose Use a pairing code. Return here and enter it while on your home Wi-Fi.": "Öppna boxen i Safari på denna iPhone. Välj Use a pairing code under Settings → FTW app. Gå tillbaka hit och ange koden medan du är på hemmets wifi.",
        "Copying the code in Safari includes the box address. You can also paste a full pairing link here.": "När du kopierar koden i Safari följer boxens adress med. Du kan också klistra in en hel parkopplingslänk här.",
        "Have only this iPhone? Open the box in Safari, then Settings → FTW app. Open the pairing link in FTW or use a pairing code.": "Har du bara denna iPhone? Öppna boxen i Safari och välj Settings → FTW app. Öppna parkopplingslänken i FTW eller använd en parkod.",
        "Enter the box address shown beside the pairing code, for example ftw.local:8080.": "Ange boxens adress som står vid parkoden, till exempel ftw.local:8080.",
        "That code has expired, was used or is incorrect. Make a new pairing code in Settings → FTW app.": "Koden har gått ut, har använts eller stämmer inte. Skapa en ny parkod under Settings → FTW app.",
        "Enter the house password you use in the box's dashboard.": "Ange det huslösenord du använder i boxens webbgränssnitt.",
        "Could not reach the box. Stay on your home Wi-Fi, check its address and allow Local Network access for FTW in iPhone Settings.": "Kunde inte nå boxen. Anslut till hemmets wifi, kontrollera adressen och tillåt Lokalt nätverk för FTW i iPhones inställningar.",
        "Could not pair with a code. Update the box, make a new code and try again, or use a picture of its QR.": "Kunde inte parkoppla med kod. Uppdatera boxen, skapa en ny kod och försök igen, eller använd en bild av QR-koden.",
        "In your box's local dashboard, open Settings → FTW app. Hold the pairing QR inside the frame.": "Öppna Settings → FTW app i boxens lokala dashboard. Håll QR-koden inom ramen.",
        "Confirm with Face ID or Touch ID if your phone asks.": "Bekräfta med Face ID eller Touch ID om telefonen frågar.",
        "Loading a simulated home.": "Laddar ett simulerat hem.",
        "Connect %@": "Anslut %@",
        "Connect this box": "Anslut den här boxen",
        "Not now": "Inte nu",
        "Open %@": "Öppna %@",
        "Scan a new pairing QR": "Skanna en ny QR-kod",
        "This link points at box %@. Connecting it replaces %@ as the home this app shows and controls. Your key for %@ stays on this phone.": "Länken pekar på boxen %@. Ansluter du den ersätter den %@ som hemmet appen visar och styr. Din nyckel för %@ finns kvar på telefonen.",
        "This link points at box %@. Only continue if you just opened Settings → FTW app and chose Show pairing code in this box's local dashboard.": "Länken pekar på boxen %@. Fortsätt bara om du nyss öppnade Settings → FTW app och valde Show pairing code i boxens lokala dashboard.",
        "Your key is still on this phone. Nothing to set up again.": "Din nyckel finns kvar på telefonen. Inget behöver ställas in igen.",
        "Connect your own box, or try a live simulated home first.": "Anslut din egen box, eller prova ett simulerat hem först.",
        "Connect your own box.": "Anslut din egen box.",
        "Use a new QR from Settings → FTW app if this key no longer works.": "Använd en ny QR-kod från Settings → FTW app om nyckeln inte längre fungerar.",
        "Interactive demo": "Interaktiv demo",
        "See a home running": "Se ett hem i drift",
        "Explore live solar, battery, grid, prices and EV charging. The data is simulated and nothing is saved.": "Utforska sol, batteri, elnät, priser och laddning av elbil live. Allt är simulerat och inget sparas.",
        "Try the live demo": "Prova demon",
        "Connect your own box": "Anslut din egen box",
        "At home, open your box's FTW dashboard, then Settings → FTW app → Show pairing code.": "Öppna boxens FTW-dashboard hemma och välj Settings → FTW app → Show pairing code.",
        "How?": "Hur?",
        "1. Open your box's local FTW dashboard while on your home network.": "1. Öppna boxens lokala FTW-dashboard när du är på hemnätverket.",
        "2. Go to Settings → FTW app.": "2. Gå till Settings → FTW app.",
        "3. Choose Show pairing code, then scan the QR here.": "3. Välj Show pairing code och skanna QR-koden här.",
        "The QR code is inside FTW Settings. It is not printed on the Raspberry Pi or its case.": "QR-koden finns i FTW:s inställningar. Den står inte på Raspberry Pi:n eller dess låda.",
        "Next, your phone asks for Face ID or Touch ID to protect your FTW key. There is no FTW account or password. If this phone loses its key, a new Settings QR is the way back.": "Sedan ber telefonen om Face ID eller Touch ID för att skydda din FTW-nyckel. Det finns inget FTW-konto och inget lösenord. Tappar telefonen nyckeln tar en ny QR-kod från Settings dig tillbaka.",
        "Can't see Show pairing code? Turn on Let the FTW app connect to this box, save, and restart the box first.": "Ser du inte Show pairing code? Slå först på Let the FTW app connect to this box, spara och starta om boxen.",
        "Choose a picture of the QR": "Välj en bild på QR-koden",
        "That link is not an FTW pairing code.": "Länken är ingen FTW-kod för parkoppling.",
        "That didn't work. Try scanning again.": "Det gick inte. Försök skanna igen.",
        "There is no FTW pairing code in that picture. Try a closer screenshot of the QR.": "Bilden har ingen FTW-kod för parkoppling. Prova en närmare skärmbild av QR-koden.",
        "That is an assistant's QR code. Connect your box first, then scan it with the iPhone Camera.": "Det är en assistents QR-kod. Anslut boxen först och skanna den sedan med iPhones kamera.",
        "The assistant's request opens once your home does.": "Assistentens begäran öppnas när ditt hem öppnas.",

        // The status line under Now's title: short words in mono caps.
        // LIVE and AS OF are the node view's, above.
        "DEMO": "DEMO",
        "CONNECTING…": "ANSLUTER…",
        "CAN'T REACH THE BOX": "NÅR INTE BOXEN",
        "PHONE OFFLINE": "TELEFONEN OFFLINE",
        "FTW BUSY": "FTW UPPTAGET",
        "BOX STARTING": "BOXEN STARTAR",
        "ACCESS ENDED": "ÅTKOMSTEN SLUT",
        "SIMULATED HOME": "SIMULERAT HEM",
        "FTW IN CONTROL": "FTW STYR",
        "YOU'RE IN CONTROL": "DU STYR",
        "▲ PAUSED": "▲ PAUSAD",
        "METER STALE": "MÄTAREN TYST",
        "▲ 1 DEVICE QUIET": "▲ 1 ENHET TYST",
        "▲ %@ DEVICES QUIET": "▲ %@ ENHETER TYSTA",
        "SENDING…": "SKICKAR…",
        "▲ NOT CONFIRMED": "▲ EJ BEKRÄFTAT",
        "Status": "Status",
        "Shows whether FTW is in control, and how it knows.": "Visar om FTW styr, och hur det vet det.",

        // The control sheet
        "Readings": "Mätvärden",
        "Read from your box at %@.": "Läst från boxen kl. %@.",
        "Your box sends no more detail to this phone.": "Boxen skickar inga fler detaljer till den här telefonen.",
        "Simulated on this phone": "Simulerade i telefonen",

        // The title's menu
        "Homes": "Hem",
        "Pair a home": "Parkoppla ett hem",
        "Settings": "Inställningar",
        "About FTW": "Om FTW",
        "Homes, settings and about.": "Hem, inställningar och om appen.",
    ]
}

/// A mode in words. The registry's keys get this app's own wording, short
/// enough for a label on Now; a mode this app has never heard of keeps the
/// box's own label, because the box is the authority on what exists.
public enum ModeWords {
    static let names: [String: String] = [
        "planner_passive_arbitrage": "Plan",
        "planner_arbitrage": "Plan, selling too",
        "planner_self": "Plan for own use",
        "planner_cheap": "Plan for cheap hours",
        "self_consumption": "Own use",
        "peak_shaving": "Peak shaving",
        "charge": "Charge the battery",
        "idle": "Stop batteries",
    ]

    static let helps: [String: String] = [
        "planner_passive_arbitrage": "Charges when power is cheap or the sun shines, covers the home when it is dear, and never sells from the battery.",
        "planner_arbitrage": "Like Plan, and also sells from the battery when the price is high enough.",
        "self_consumption": "No plan. The battery takes spare solar and covers the home as it happens.",
        "peak_shaving": "No plan. The battery holds what the home buys under the peak limit.",
        "charge": "No plan. Charges the battery full whatever the price.",
        "idle": "No plan. Every battery holds at 0 W. Fuse protection and car charging carry on.",
    ]

    public static func name(_ mode: ModeInfo?) -> String {
        guard let mode else { return "—" }
        return names[mode.key].map(NodeWords.text) ?? mode.label
    }

    public static func help(_ mode: ModeInfo?) -> String {
        guard let mode else { return "" }
        return helps[mode.key].map(NodeWords.text) ?? mode.tooltip
    }

    /// A mode the planner drives, rather than a manual fallback.
    public static func isPlan(_ key: String?) -> Bool { key?.hasPrefix("planner_") ?? false }
}
