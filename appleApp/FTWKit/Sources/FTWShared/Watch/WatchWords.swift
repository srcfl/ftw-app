import Foundation

/// Every sentence the watch shows that the phone's widgets do not. The
/// English is the key; the Swedish lives in `Resources/sv.lproj/Watch.strings`,
/// and a test checks each one has it. The status line and the receipt use
/// the phone's words (`LIVE · FTW STYR`, `SKICKAT ▸ MOTTAGET ▸ BEKRÄFTAT`),
/// so the two screens say the same thing.
public enum WatchWord: String, CaseIterable, Sendable {
    // The status line, in the terminal's caps.
    case live = "LIVE"
    case demo = "DEMO"
    case asOf = "AS OF %@"
    case noReadingYet = "NO READING YET"
    case inControl = "FTW IN CONTROL"
    case notInControl = "▲ FTW NOT IN CONTROL"
    case planned = "PLANNED %@"
    case planFrom = "PLAN FROM %@"

    // The receipt.
    case sent = "SENT"
    case accepted = "ACCEPTED"
    case confirmed = "CONFIRMED"
    case sending = "SENDING…"
    case notConfirmed = "▲ NOT CONFIRMED"
    case notSent = "▲ NOT SENT"
    case sendingToPhone = "Sending to your iPhone…"
    case phoneSending = "Your iPhone is sending it to your box…"
    case phoneUnreachableNothingSent = "Your iPhone can't be reached. Nothing was sent."
    case noAnswerCheckPhone = "No answer from your iPhone yet. Check FTW there."
    case tooLate = "That came too late, so it was not sent. Try again."
    case otherHome = "That was for another home. Nothing was sent."
    case cannotChangeMode = "This phone may not change how the home is run."

    // Where the watch stands.
    case phoneUnreachable = "iPhone not reachable"
    case openOnPhone = "Open FTW on your iPhone"
    case openOnPhoneDetail = "The watch shows what your iPhone last read. Pair the phone with your box first."

    // Now's nodes and their words.
    case solar = "Solar"
    case battery = "Battery"
    case home = "Usage"
    case grid = "Grid"
    case car = "Car"
    case making = "making"
    case resting = "resting"
    case charging = "charging"
    case giving = "giving power"
    case using = "using"
    case buying = "buying"
    case selling = "selling"
    case balanced = "balanced"
    case noReading = "no reading"

    // The pages.
    case nowTitle = "Now"
    case planTitle = "Plan"
    case priceTitle = "Price"
    case mode = "Mode"

    // The plan dial.
    case batteryStores = "Battery stores"
    case batteryGives = "Battery gives power"
    case batteryWaits = "Battery waits"
    case noPlan = "No plan"
    case carCharges = "car charges"
    case carGoal = "car %@"
    case cheapestMark = "cheapest"
    case noPriceYet = "No price yet"
    case turnTheCrown = "Turn the Crown to step through the plan"

    // The car.
    case pluggedIn = "Plugged in"
    case notPluggedIn = "Not plugged in"
    case chargeNowOn = "Charge now on"
    case chargingAt = "Charging · %@"
    case goal = "Goal %@"
    case chargesAt = "Charges %@"
    case levelAssumed = "%@ assumed"
    case noCharger = "FTW has no charger"
    case whichCar = "Which car?"
    case noneOfThese = "None of these"
    case chooseCarAsk = "Is %@ the car on the charger?"
    case fromCar = "from the car · %@"
    case setByHand = "set by hand · %@"
    case estimated = "≈ %@"
    case assumedAtPlugIn = "assumed at plug-in"
    case chargeNow = "Charge now"
    case pause = "Pause"
    case backToPlan = "Back to the plan"
    case chargeNowAsk = "Start charging at once, until you go back to the plan?"
    case pauseAsk = "Stop charging until you go back to the plan?"
    case backToPlanAsk = "Let FTW decide when to charge again?"
    case modeAsk = "Run the home as %@?"
    case cancel = "Cancel"

    // The price.
    case priceNow = "Price now"
    case cheapNow = "Cheap now"
    case cheapUntil = "until %@"
    case cheapWidget = "Cheap power"
    case cheapWidgetSummary = "Shows up in the Smart Stack while power is at its cheapest."
    case planWidget = "FTW plan"
    case planWidgetSummary = "The next 24 hours on a dial, and what FTW plans now."

    public var text: String { Words.bundle.localizedString(forKey: rawValue, value: rawValue, table: "Watch") }

    public func format(_ args: String...) -> String {
        var out = text
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }
}
