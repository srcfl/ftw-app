import Foundation
import Testing
@testable import FTWKit

@MainActor
@Suite struct SessionTests {
    @Test func theWholeStackReachesAStream() async throws {
        let rig = Rig()
        await rig.run(200)
        #expect(rig.session.state.phase == .streaming)
        #expect(rig.session.state.carrier == .relay)
        #expect(rig.session.state.heardFromBox)
        #expect(rig.session.state.caps.contains(Contract.capAPIPassthrough))
        #expect(rig.session.state.fields[Contract.FID.gridW] != nil)
        #expect(rig.session.state.modes.first?.key == "planner_passive_arbitrage")
        // The pairing code travelled, encrypted, in message 1.
        #expect(rig.endpoint.handshakePayloads.first == rig.pairingCode)

        // The relay only ever saw the rotating handle, never a key.
        let url = try #require(rig.relay.dialled.first)
        let parts = url.path.split(separator: "/")
        #expect(parts.count == 4)
        #expect(parts[0] == "r")
        #expect(parts[3] == "app")
        #expect(String(parts[2]) == (try Rendezvous.handle(secret: Bytes(repeating: 9, count: 32), epoch: Int64(parts[1])!)))
    }

    @Test func laneZeroFramesAreOneSizeOnTheWire() async throws {
        let rig = Rig()
        await rig.run(5_000, step: 100)
        // Everything the app sent after the handshake on lane 0: hello, sub.
        let sent = try #require(rig.relay.current?.sent)
        let transport = sent.dropFirst()
        #expect(!transport.isEmpty)
        #expect(Set(transport.map(\.count)) == [512 + NoiseTransport.overhead])
    }

    @Test func telemetryKeepsArriving() async {
        let rig = Rig()
        await rig.run(200)
        let before = rig.session.state.uptimeMs
        await rig.run(3_000, step: 100)
        #expect(rig.session.state.uptimeMs > before)
    }

    @Test func theBoxsOwnAPIAnswersInJSON() async throws {
        let rig = Rig()
        await rig.run(200)
        let task = Task { try await rig.session.api(APIRequest(method: .get, path: "/api/status")) }
        await rig.run(200)
        let response = try await task.value
        #expect(response.status == 200)
        let json = try JSON(parsing: response.body)
        #expect(json["fuse"]?["max_amps"]?.number == 25)
    }

    @Test func aLargeAnswerArrivesInOrderedChunks() async throws {
        let rig = Rig()
        await rig.run(200)
        // Ninety days of ledger is several chunks.
        let task = Task { try await rig.session.api(APIRequest(method: .get, path: "/api/energy/daily", query: ["days": "90"])) }
        await rig.run(300)
        let response = try await task.value
        #expect(response.body.count > 12_288)
        #expect(try JSON(parsing: response.body)["days"]?.array?.count == 90)
    }

    @Test func refusalsArriveAsCodesAndNoHandlerRan() async throws {
        let rig = Rig(requireStepUp: true)
        await rig.run(200)
        for (req, code) in [
            (APIRequest(method: .post, path: "/api/restart"), "E_NEEDS_STEP_UP"),
            (APIRequest(method: .post, path: "/api/mode"), "E_USE_CMD"),
            (APIRequest(method: .get, path: "/api/config"), "E_LOCAL_ONLY"),
            (APIRequest(method: .get, path: "/api/nothing/here"), "E_UNKNOWN_OP"),
        ] {
            let task = Task { try await rig.session.api(req) }
            await rig.run(100)
            do {
                _ = try await task.value
                Issue.record("\(req.path) answered")
            } catch let refusal as BoxRefusal {
                #expect(refusal.detail.code == code)
            }
        }
        // The same request with the flag goes through.
        let task = Task { try await rig.session.api(APIRequest(method: .post, path: "/api/restart", stepUp: true)) }
        await rig.run(100)
        #expect(try await task.value.status == 200)
    }

    @Test func oneAPICallIsOnTheWireAtATime() async throws {
        let rig = Rig()
        await rig.run(200)
        let a = Task { try await rig.session.api(APIRequest(method: .get, path: "/api/status")) }
        let b = Task { try await rig.session.api(APIRequest(method: .get, path: "/api/loadpoints")) }
        await rig.run(400)
        #expect(try await a.value.status == 200)
        #expect(try await b.value.status == 200)
    }

    @Test func aModeCommandIsAckedAppliedAndReplans() async throws {
        let rig = Rig()
        await rig.run(200)
        let task = Task { try await rig.session.command(Contract.opSetMode, args: [("mode", .text("self_consumption"))]) }
        await rig.run(200)
        let result = try await task.value
        #expect(result.state == .applied)
        #expect(result.observedValue == 3)
        // The plan pushed unasked lands on state.
        #expect(rig.session.state.plan != nil)
        await rig.run(1_500, step: 100)
        #expect(rig.session.state.fields[Contract.FID.mode] == 3)
    }

    @Test func noAckMeansItNeverReachedTheBox() async throws {
        let rig = Rig()
        await rig.run(200)
        rig.box.mute = true
        let task = Task { try await rig.session.command(Contract.opSetMode, args: [("mode", .text("idle"))]) }
        await rig.run(Session.cmdAckTimeoutMs + 100, step: 100)
        do {
            _ = try await task.value
            Issue.record("a silent box confirmed")
        } catch let e as CommandError {
            #expect(e.code == "E_NO_ACK")
        }
    }

    @Test func ackedButNeverConfirmedIsItsOwnAnswer() async throws {
        let rig = Rig()
        await rig.run(200)
        rig.box.neverConfirm = true
        let task = Task { try await rig.session.command(Contract.opSetMode, args: [("mode", .text("idle"))]) }
        await rig.run(Session.cmdConfirmTimeoutMs + 200, step: 100)
        #expect(try await task.value.state == .unconfirmed)
    }

    @Test func aDropSettlesEveryRequestInFlight() async throws {
        let rig = Rig()
        await rig.run(200)
        rig.box.mute = true
        let task = Task { try await rig.session.plan() }
        await rig.run(50)
        rig.relay.closeCurrent(code: 1006, reason: "")
        await rig.run(20)
        await #expect(throws: SessionError.carrierClosed) { _ = try await task.value }
        #expect(rig.session.state.phase == .failed)
        // Readings stay, older.
        #expect(!rig.session.state.fields.isEmpty)
    }

    @Test func theSessionComesBackAfterADrop() async throws {
        let rig = Rig()
        await rig.run(200)
        rig.relay.closeCurrent(code: 1006, reason: "")
        // Full-jitter backoff at the scheduler's 0.5: 250 ms, then a new
        // socket, a new handshake and a new stream.
        rig.endpoint.dropSession()
        await rig.run(1_000, step: 20)
        #expect(rig.session.state.phase == .streaming)
        #expect(rig.relay.dialled.count == 2)
    }

    @Test func theBoxLeavingAndReturningKeepsOneSocket() async throws {
        let rig = Rig()
        await rig.run(200)
        rig.relay.boxLeaves()
        await rig.run(20)
        #expect(rig.session.state.phase == .failed)
        rig.relay.boxReturns()
        await rig.run(300)
        #expect(rig.session.state.phase == .streaming)
        #expect(rig.relay.dialled.count == 1)
    }

    @Test func aRelayEpochCorrectionIsTakenOnlyWhenSmall() async throws {
        let rig = Rig()
        await rig.run(200)
        let ours = Rendezvous.epoch(nowMs: rig.scheduler.nowMs)
        rig.relay.closeCurrent(code: RelayCarrier.closeEpoch, reason: String(ours + 1))
        await rig.run(100)
        let corrected = try #require(rig.relay.dialled.last)
        #expect(corrected.path.split(separator: "/")[1] == Substring(String(ours + 1)))

        // A relay naming an epoch a year away is not a clock correction.
        rig.relay.closeCurrent(code: RelayCarrier.closeEpoch, reason: String(ours + 9_000))
        await rig.run(100)
        let refused = try #require(rig.relay.dialled.last)
        #expect(refused.path.split(separator: "/")[1] == Substring(String(ours + 1)))
    }

    @Test func aSilentBoxEndsTheHandshakeAndItIsRetried() async throws {
        let rig = Rig(connect: false)
        rig.endpoint.refuse = true
        rig.session.connect(rig.noise)
        await rig.run(NoiseCarrier.handshakeDeadlineMs + 100, step: 200)
        if case .closed(let reason, let retryable) = rig.noise.status {
            #expect(reason == "the box did not answer")
            #expect(retryable)
        } else {
            Issue.record("still \(rig.noise.status)")
        }
        rig.endpoint.refuse = false
        await rig.run(20_000, step: 200)
        #expect(rig.session.state.phase == .streaming)
    }

    @Test func aForeignFrameOnTheRoomIsIgnored() async throws {
        let rig = Rig()
        await rig.run(200)
        rig.relay.current?.deliver(randomBytes(528))
        rig.relay.current?.deliver(randomBytes(48))
        await rig.run(1_500, step: 100)
        #expect(rig.session.state.phase == .streaming)
    }

    @Test func aStartingBoxIsAskedAgainOnItsOwnTimer() async throws {
        let rig = Rig(connect: false)
        rig.box.booting = true
        rig.session.connect(rig.noise)
        await rig.run(200)
        #expect(rig.session.state.phase == .booting)
        #expect(rig.session.state.boot?.phase == "vacuum")
        rig.box.booting = false
        await rig.run(Session.bootRetryMs + 200, step: 100)
        #expect(rig.session.state.phase == .streaming)
    }

    @Test func historyArrivesAsTilesAndAssembles() async throws {
        let rig = Rig()
        await rig.run(200)
        let to = rig.scheduler.nowMs
        let from = to - 86_400_000
        var chunks = [String: HistChunk]()
        let task = Task {
            try await rig.session.history(HistQuery(series: ["grid_w", "pv_w", "battery_w", "load_w"], res: .fiveMinutes, fromMs: from, toMs: to, have: [], maxPoints: 1500)) { chunk in
                chunks[chunk.tileId] = chunk
            }
        }
        await rig.run(300)
        let end = try await task.value
        #expect(end.resActual == .fiveMinutes)
        let plan = HistoryGeometry.plan(.fiveMinutes, fromMs: from, toMs: to, maxPoints: 1500)
        #expect(Set(chunks.keys) == Set(plan.tiles.map(\.tileId)))
        let frame = HistoryGeometry.clip(HistoryGeometry.assemble(plan, names: ["grid_w", "pv_w", "battery_w", "load_w"], tiles: chunks), fromMs: from, toMs: to)
        #expect(frame.points >= 287 && frame.points <= 289)
        #expect(frame.value("load_w", at: 0) != nil)
    }

    @Test func pricesAndThePlanAreAsked() async throws {
        let rig = Rig()
        await rig.run(200)
        let plan = Task { try await rig.session.plan() }
        let prices = Task { try await rig.session.prices(fromMs: rig.scheduler.nowMs, toMs: rig.scheduler.nowMs + 86_400_000) }
        await rig.run(200)
        #expect(try await plan.value.slots.count == 96)
        #expect(try await prices.value.currency == "SEK")
    }

    @Test func revocationTerminatesAndSaysWhy() async throws {
        let rig = Rig()
        await rig.run(200)
        let frame = try Frame.encodeBulk(envelope: Envelope(t: "session.terminate", b: .map([("reason", .text("revoked"))])))
        rig.box.send?(frame)
        await rig.run(50)
        #expect(rig.session.state.phase == .terminated)
        #expect(rig.session.state.terminated == .revoked)
    }

    @Test func cachedReadingsNeverOverwriteALiveCarrier() async throws {
        let rig = Rig()
        // Until the handshake to the box completes, the cache is honestly
        // what is on screen.
        var old = SessionState()
        old.fields = [Contract.FID.gridW: 1_234]
        for _ in 0..<20 where rig.session.state.phase != .handshaking {
            await rig.run(5, step: 5)
        }
        #expect(rig.session.state.phase == .handshaking)
        // Mid-handshake: the cache paints data, never the phase or carrier.
        rig.session.restore(CachedSnapshot(siteId: "s", savedAtMs: 0, state: old))
        #expect(rig.session.state.phase == .handshaking)
        #expect(rig.session.state.carrier == .relay)
        #expect(rig.session.state.fields[Contract.FID.gridW] == 1_234)
        await rig.run(200)
        #expect(rig.session.state.phase == .streaming)
        rig.session.restore(CachedSnapshot(siteId: "s", savedAtMs: 0, state: old))
        #expect(rig.session.state.fields[Contract.FID.gridW] != 1_234)
    }
}

@Suite struct HistoryGeometryTests {
    @Test func wideWindowsClampToTheHourlyStore() {
        let now = 1_750_000_000_000.0
        let year = HistoryGeometry.plan(.fiveMinutes, fromMs: now - 365 * 86_400_000, toMs: now, maxPoints: 1500)
        #expect(year.res == .hour)
        #expect(year.tiles.count * year.tiles[0].points <= 1500 * 2)
        let day = HistoryGeometry.plan(.fiveMinutes, fromMs: now - 86_400_000, toMs: now, maxPoints: 1500)
        #expect(day.res == .fiveMinutes)
        #expect(day.stride == 1)
    }

    @Test func packingRoundTripsAndKeepsTheMissingMarker() {
        let columns: [[Int32]] = [[1, -2, missingSample], [Int32.max, 0, 7]]
        #expect(HistoryGeometry.unpack(HistoryGeometry.pack(columns), seriesCount: 2) == columns)
    }

    @Test func etagIsFNV1a() {
        #expect(HistoryGeometry.etag([]) == "811c9dc5")
        #expect(HistoryGeometry.etag(Array("a".utf8)) == "e40c292c")
    }
}

@Suite struct ContractTests {
    /// The registry is one file shared with the box and the web app. Every
    /// name this app spells has to be the registry's.
    @Test func namesMatchTheSharedRegistry() throws {
        let yaml = try RepoFiles.read("protocol/registry.yaml")
        func names(section: String, key: String) -> [String] {
            var out = [String]()
            var inside = false
            for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("\(section):") { inside = true; continue }
                if inside, let first = line.first, !first.isWhitespace, first != "#" { break }
                guard inside, let range = line.range(of: "\(key): ") else { continue }
                let rest = line[range.upperBound...]
                out.append(String(rest.prefix { $0 != "," && $0 != "}" && $0 != " " }))
            }
            return out
        }
        func list(section: String) -> [String] {
            var out = [String]()
            var inside = false
            for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("\(section):") { inside = true; continue }
                if inside, let first = line.first, !first.isWhitespace, first != "#" { break }
                let t = line.trimmingCharacters(in: .whitespaces)
                if inside, t.hasPrefix("- ") { out.append(String(t.dropFirst(2))) }
            }
            return out
        }

        #expect(names(section: "scopes", key: "name") == Contract.scopes)
        #expect(names(section: "ops", key: "name") == Contract.ops)
        #expect(list(section: "capabilities") == Contract.capabilities)
        let errors = names(section: "errors", key: "code") + names(section: "client_errors", key: "code")
        #expect(Set(errors) == Set(Contract.retryable.keys))
        for code in errors {
            let line = yaml.split(separator: "\n").first { $0.contains("code: \(code),") }!
            #expect(line.contains("retryable: \(Contract.isRetryable(code))"), "\(code)")
        }
        #expect(yaml.contains("source_states: [\(Contract.sourceStates.joined(separator: ", "))]"))
        #expect(yaml.contains("carrier_states: [\(Contract.carrierStates.joined(separator: ", "))]"))
        #expect(yaml.contains("1: { name: mode,"))
        #expect(yaml.contains("10: { name: ev_w,"))
    }
}
