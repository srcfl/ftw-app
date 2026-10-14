import Foundation
import Testing
@testable import FTWDemo
@testable import FTWKit
import FTWShared

/// The control sheet says what the box's own page says. These follow the
/// box's web/control-feedback.test.mjs, case for case where they overlap.
@Suite struct ControlFeedbackTests {
    static let utc = TimeZone(identifier: "UTC")!

    /// The box's test row: a battery discharging 2.25 kW on the plan.
    func row(_ change: (inout ControlRow) -> Void = { _ in }) -> ControlRow {
        var r = ControlRow(driver: "bat", kind: "battery", mode: "planner_arbitrage", status: "following", reason: "power_observed", severity: "info", evidence: "measured")
        r.readingsFresh = true
        r.sentW = -2250
        r.requestedW = -2250
        r.actualW = -2249
        r.readbackW = -2250
        r.commandAtMs = 1
        r.observedAtMs = 2
        r.siteConfirmation = "device_response_unconfirmed"
        change(&r)
        return r
    }

    /// Every reason the box's page has words for, so none shows as a code.
    static let reasons = [
        "power_observed", "plan", "manual_hold", "pv_surplus", "idle", "solar_below_ceiling", "vehicle_complete",
        "vehicle_limit_completion", "vehicle_not_requesting", "waiting_response", "no_command", "not_connected",
        "no_plan_budget", "pv_surplus_pause", "wake_kick", "battery_full", "battery_nearly_full", "battery_nearly_empty",
        "core_limit", "fuse_limit", "fuse_cooldown", "charger_limit", "device_limit", "offered_current_lower",
        "power_below_target", "power_above_target", "power_wrong_direction", "no_power_response", "power_while_idle",
        "setpoint_changed", "device_fault", "telemetry_stale", "readings_lost", "command_failed", "command_unconfirmed",
        "default_failed", "response_unknown", "observe_only", "disabled", "device_control", "site_meter_stale",
        "site_phase_currents_stale",
    ]

    @Test func everyReasonHasATitleAndASentence() {
        for language in [AppWords.Language.en, .sv] {
            AppWords.$language.withValue(language) {
                for reason in Self.reasons {
                    let words = ControlFeedback.status(row { $0.reason = reason; $0.status = "waiting" }, zone: Self.utc)
                    #expect(!words.text.contains("cannot describe") && !words.text.contains("inte kan beskriva"), "\(reason)")
                    #expect(!words.title.isEmpty && words.title != ControlWords.text("Checking"), "\(reason)")
                    let shown = [words.title, words.text, words.proof, words.next].joined(separator: " ")
                    #expect(shown.range(of: #"_|undefined|NaN|null|%@"#, options: .regularExpression) == nil, "\(reason): \(shown)")
                }
            }
        }
    }

    @Test func theAnswerFollowsCore() {
        AppWords.$language.withValue(.en) {
            let following = ControlFeedback.status(row(), zone: Self.utc)
            #expect(following.title == "Following FTW")
            #expect(following.text == "Discharging 2.2 kW as planned.")
            #expect(following.proof == "Based on the battery’s own readings.")
            #expect(following.tone == .ok)

            let ignored = ControlFeedback.status(row { $0.status = "not_following"; $0.reason = "no_power_response"; $0.severity = "warning"; $0.sentW = 3000; $0.actualW = 0 }, zone: Self.utc)
            #expect(ignored.title == "Not following")
            #expect(ignored.text == "Asked for 3.0 kW charge, but it delivers no power.")
            #expect(ignored.next.contains("has not said why"))
            #expect(ignored.tone == .warning)

            let lost = ControlFeedback.status(row { $0.status = "no_contact"; $0.reason = "readings_lost"; $0.severity = "alarm"; $0.evidence = "accepted" }, zone: Self.utc)
            #expect(lost.title == "Lost control")
            #expect(lost.tone == .alarm)
            #expect(ControlFeedback.status(row(), live: false).tone == .stale)
        }
    }

    @Test func expectedLimitsStayCalmAndExplainThemselves() {
        AppWords.$language.withValue(.en) {
            let taper = ControlFeedback.status(row { $0.status = "limited"; $0.reason = "battery_nearly_full"; $0.sentW = 3000; $0.actualW = 900; $0.batterySoc = 0.98 })
            #expect(taper.title == "Battery nearly full")
            #expect(taper.text == "Taking 900 W of 3.0 kW at 98\u{00A0}%. A battery charges slower when it is nearly full.")
            #expect(taper.tone == .neutral)
            let full = ControlFeedback.status(row { $0.status = "limited"; $0.reason = "battery_full"; $0.sentW = 0; $0.actualW = 0; $0.batterySoc = 1; $0.chargeResumeSoc = 0.99 })
            #expect(full.text.contains("paused charging at 100\u{00A0}%. Charging resumes at 99\u{00A0}% or lower"))
            #expect(ControlFeedback.status(row { $0.kind = "ev"; $0.reason = "vehicle_complete"; $0.mode = "plan" }).title == "Car is full")
            let limit = ControlFeedback.status(row { $0.kind = "ev"; $0.status = "limited"; $0.reason = "device_limit"; $0.severity = "warning"; $0.deviceLimitA = 8; $0.requestedA = 16 })
            #expect(limit.text == "The charger’s own limit is 8 A, below the 16 A FTW asked for.")
        }
    }

    /// How FTW knows: sent, accepted, measured, confirmed, each with its
    /// value and state, and a confirmed change says what the meter saw.
    @Test func theReceiptWalksSentAcceptedMeasuredConfirmed() {
        AppWords.$language.withValue(.en) {
            let measured = ControlFeedback.receipt(row(), zone: Self.utc)
            #expect(measured.map(\.step) == ["Sent", "Accepted", "Measured", "Confirmed"])
            #expect(measured.map(\.state) == [.done, .done, .done, .wait])
            #expect(measured[1].value == "The battery reports target 2.3 kW discharge")
            #expect(measured[3].value == "Waits for the device’s measured response")

            var comparison = ControlRow.Comparison()
            comparison.deviceChangeW = -1800
            let confirmed = ControlFeedback.receipt(row { $0.evidence = "confirmed"; $0.confirmedAtMs = CarTextTests.t; $0.siteEvidence = comparison }, zone: Self.utc)
            #expect(confirmed.last?.state == .done)
            #expect(confirmed.last?.value == "The grid meter matched a 1.8 kW change · 10:00")

            let failed = ControlFeedback.receipt(row { $0.reason = "command_failed"; $0.evidence = "" })
            #expect(failed[1].state == .fail)
            #expect(failed[1].value == "Commands failing")

            // Asked differs from sent: the plan's wish shows first.
            let asked = ControlFeedback.receipt(row { $0.requestedW = -4000 })
            #expect(asked.first?.step == "Asked")
            #expect(asked.first?.value == "4.0 kW discharge · plan")

            let old = ControlFeedback.receipt(row(), live: false)
            #expect(old[2].value == "Not current")
            #expect(old[2].state == StepState.none)
        }
    }

    typealias StepState = ControlFeedback.StepState

    @Test func theSummaryCountsWhatNeedsAttention() {
        AppWords.$language.withValue(.en) {
            #expect(ControlFeedback.summary([row()]).title == "Yes, FTW is in control")
            #expect(ControlFeedback.summary([row { $0.severity = "warning" }, row()]).title == "1 device needs a look")
            #expect(ControlFeedback.summary([row { $0.severity = "alarm" }, row { $0.severity = "alarm" }]).tone == .alarm)
            #expect(ControlFeedback.summary([row { $0.status = "not_controlled" }]).title == "FTW controls no device right now")
            #expect(ControlFeedback.summary([row()], live: false).tone == .stale)
        }
    }

    /// Numbers say direction in words, never with a bare sign.
    @Test func theNumbersHaveNoMinusSign() {
        AppWords.$language.withValue(.en) {
            var e = ControlRow.Comparison()
            e.gridBeforeW = -1200
            e.gridAfterW = 600
            e.deviceChangeW = -1800
            e.gridChangeW = 1800
            e.samples = 8
            e.windowS = 12
            let numbers = ControlFeedback.numbers(row { $0.batterySoc = 0.62; $0.toleranceW = 150; $0.siteEvidence = e })
            let shown = Dictionary(uniqueKeysWithValues: numbers)
            #expect(shown["Battery charge"] == "62\u{00A0}%")
            #expect(shown["Grid before"] == "1.2 kW export")
            #expect(shown["Device change"] == "1.8 kW toward discharge")
            #expect(shown["Compared"] == "8 readings over 12 s")
            #expect(!numbers.contains { $0.1.contains("-") })
        }
    }

    @Test func inSwedish() {
        AppWords.$language.withValue(.sv) {
            let following = ControlFeedback.status(row())
            #expect(following.title == "Följer FTW")
            #expect(following.text == "Laddar ur 2,2 kW enligt planen.")
            #expect(following.proof == "Bygger på batteriets egna mätvärden.")
            #expect(ControlFeedback.status(row { $0.reason = "telemetry_stale" }).next == "Kontrollera anslutningen till batteriet.")
            #expect(ControlFeedback.receipt(row()).map(\.step) == ["Skickat", "Mottaget", "Mätt", "Bekräftat"])
        }
    }

    /// Every word the sheet hands to `ControlWords` has Swedish. Read from
    /// the source, so a new sentence without Swedish fails here.
    @Test func everyWordHasSwedish() throws {
        let source = try RepoFiles.read("appleApp/FTWKit/Sources/FTWKit/Format/ControlFeedback.swift")
            + RepoFiles.read("appleApp/FTW/UI/ControlSheet.swift")
        let call = #/(?:ControlWords|\bw)\.(?:text|format)\("((?:[^"\\]|\\.)*)"/#
        var english = Set(source.matches(of: call).map { String($0.1) })
        english.formUnion(ControlFeedback.statusTitles.values)
        english.formUnion(ControlFeedback.reasonTitles.values)
        english.formUnion(ControlFeedback.confirmation.values.map(\.0))
        // Words picked by a ternary inside a call: the call only sees the first.
        english.formUnion(["%@ discharge", "%@ less solar", "%@ more charging", "%@ toward charge", "%@ import", "%@ toward import", "%@ more drawn",
                           "%@ device needs attention now", "%@ devices need attention now", "%@ device needs a look", "%@ devices need a look",
                           "producing", "idle", "charging", "discharging", "two minutes", "15 seconds", "no charging", "%@ export",
                           "%@ more solar", "%@ less charging", "%@ toward discharge", "%@ toward export", "%@ less drawn", "%@ charge",
                           "car charger", "meter", "battery", "solar", "charger", "device"])
        #expect(english.count > 120)
        for en in english.sorted() where !en.isEmpty {
            #expect(ControlWords.sv[en] != nil || NodeWords.sv[en] != nil || AppWords.sv[en] != nil, "no Swedish for \"\(en)\"")
        }
        for (en, sv) in ControlWords.sv {
            #expect(!sv.isEmpty)
            #expect(en.components(separatedBy: "%@").count == sv.components(separatedBy: "%@").count, "\(en)")
        }
    }

    /// The demo box answers with rows of the same shape as a real box.
    @MainActor
    @Test func theDemoBoxAnswersWithControlRows() async throws {
        let rig = DemoRig()
        rig.app.startDemo()
        let home = try #require(rig.app.home)
        await rig.run(3_000)
        let check = ControlCheck(site: home.site)
        #expect(check.canRead)
        let read = Task { await check.read() }
        await rig.run(1_000)
        await read.value
        #expect(check.rows.map(\.id) == ["sungrow:battery", "easee:ev"])
        #expect(check.live)
        AppWords.$language.withValue(.en) {
            #expect(ControlFeedback.summary(check.rows).title == "Yes, FTW is in control")
            #expect(!ControlFeedback.status(check.rows[0]).text.isEmpty)
        }
        // A new key only when something about control changed.
        let key = check.key
        await rig.run(5_000)
        #expect(check.key == key)
    }
}
