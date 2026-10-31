import Foundation

/// Names from protocol/registry.yaml, in Swift.
///
/// The registry is one file shared byte for byte with srcfl/ftw and
/// srcfl/ftw-webapp. There is no generator here, so this is written by hand
/// and `ContractTests` reads the registry back and fails when anything has
/// stopped matching. Add nothing here that is not in the registry.
public enum Contract {
    /// An object and a verb: `<object>.<read|write|run|hold|request>`.
    /// read and write are a phone's; run, hold and request are an agent's
    /// (docs/agents.md in srcfl/ftw).
    public static let scopes = [
        "ftw.live.read",
        "ftw.history.read",
        "ftw.plan.read",
        "ftw.health.read",
        "ftw.assets.read",
        "ftw.events.read",
        "ftw.dispatch.write",
        "ftw.mode.write",
        "ftw.members.read",
        "ftw.members.write",
        "ftw.logs.read",
        "ftw.config.read",
        "ftw.diag.run",
        "ftw.setup.write",
        "ftw.dispatch.hold",
        "ftw.goals.request",
        "ftw.update.request",
        "ftw.cars.read",
        "ftw.cars.write",
    ]

    public static let roleOwner = "owner"
    public static let roleViewer = "viewer"
    public static let roleWatch = "watch"

    /// What each role carries, with the registry's `*` expanded. Used only
    /// for a box from before roles, which sends no scope list.
    public static let roleScopes: [String: [String]] = [
        roleOwner: scopes,
        roleViewer: ["ftw.live.read"],
        roleWatch: ["ftw.live.read", "ftw.plan.read", "ftw.events.read", "ftw.dispatch.write"],
    ]

    public static let roleLabels: [String: String] = [
        roleOwner: "Owner",
        roleViewer: "Viewer",
        roleWatch: "Watch",
        roleAgent: "Assistant",
        roleSupport: "Sourceful support",
        roleRelease: "Release check",
    ]

    /// Grants an owner gives to something other than a paired device
    /// (docs/agents.md in srcfl/ftw). A role is the most a grant of that
    /// kind may carry; each grant names a subset.
    public static let roleAgent = "agent"
    public static let roleSupport = "support"
    public static let roleRelease = "release"
    public static let agentRoleScopes: [String: [String]] = [
        roleAgent: agentScopes,
        roleSupport: agentScopes,
        roleRelease: ["ftw.health.read"],
    ]
    static let agentScopes = [
        "ftw.live.read", "ftw.history.read", "ftw.plan.read", "ftw.health.read", "ftw.events.read",
        "ftw.logs.read", "ftw.config.read", "ftw.diag.run", "ftw.setup.write", "ftw.dispatch.hold", "ftw.goals.request",
    ]

    /// Each scope's description, from the registry. Words for an owner come
    /// from `AccessWords`; this is what they translate.
    public static let scopeDescs: [String: String] = [
        "ftw.live.read": "Current readings and freshness",
        "ftw.history.read": "Stored history",
        "ftw.plan.read": "Dispatch plan and its reasoning",
        "ftw.health.read": "Box and driver health",
        "ftw.assets.read": "Devices and their capabilities",
        "ftw.events.read": "Events behind notifications",
        "ftw.dispatch.write": "Control energy assets",
        "ftw.mode.write": "Change site operating mode",
        "ftw.members.read": "See who has access",
        "ftw.members.write": "Invite and revoke",
        "ftw.logs.read": "Log excerpts the box redacts",
        "ftw.config.read": "Configuration the box redacts",
        "ftw.diag.run": "Full technical diagnostics and read API",
        "ftw.setup.write": "Save confirmed system setup and restart to apply it after user confirmation",
        "ftw.dispatch.hold": "Hold energy assets for a capped time",
        "ftw.goals.request": "Ask an owner to change a durable goal",
        "ftw.update.request": "Ask an owner to install a version",
        "ftw.cars.read": "See the owner's cars with their VINs and identifiers and sources",
        "ftw.cars.write": "Keep the owner's list of cars",
    ]

    public static let scopeModeWrite = "ftw.mode.write"
    /// The owner's list of cars: `car.add`, `car.update`, `car.remove`.
    public static let scopeCarsWrite = "ftw.cars.write"

    public static let capabilities = [
        "status.core", "status.phases", "status.drivers",
        "history.5m", "history.1h", "history.etag",
        "cmd.lease", "cmd.precondition", "cmd.readback",
        "der.battery", "der.ev", "der.v2x",
        "plan.dispatch", "net.webrtc", "price.spot", "api.passthrough",
        "cloud.link", "cloud.tun", "cmd.exchange", "access.agents", "access.invites", "der.car",
    ]

    public static let capHistory5m = "history.5m"
    public static let capPlanDispatch = "plan.dispatch"
    public static let capDerEV = "der.ev"
    public static let capPriceSpot = "price.spot"
    public static let capAPIPassthrough = "api.passthrough"
    /// The box can run the FTW Cloud uplink. Absent, the app offers no FTW
    /// Cloud and reads through the relay alone.
    public static let capCloudLink = "cloud.link"
    /// The box takes its app session through FTW Cloud's tunnel. Absent,
    /// the phone reaches it through the relay, home id or not.
    public static let capCloudTun = "cloud.tun"
    /// The box can take a watch. Absent, the phone offers no Add watch.
    public static let capCmdExchange = "cmd.exchange"
    /// The box takes agents and answers the agent messages. Absent, the app
    /// offers no Access list.
    public static let capAccessAgents = "access.agents"
    public static let capAccessInvites = "access.invites"

    /// The scopes an FTW Cloud grant may name, and what its data may be
    /// used for: the registry's `cloud_scopes` and `cloud_purposes`.
    public static let cloudScopes = ["ftw.live.read", "ftw.history.read", "ftw.plan.read", "ftw.health.read", "ftw.events.read"]
    public static let cloudPurposes = ["serve", "stats"]
    public static let cloudPurposeStats = "stats"

    public static let opSetMode = "site.mode.set"
    public static let opPlannerPrefsSet = "planner.prefs.set"
    /// Offer the phone's time zone as the household clock. The box takes it
    /// only while it keeps none; a box that keeps one answers E_PRECONDITION
    /// with the zone it keeps in args.tz.
    public static let opSiteTimeZonePropose = "site.time_zone.propose"
    public static let opBatteryHold = "battery.hold"
    public static let opLoadpointHold = "loadpoint.hold"
    public static let opLoadpointBoost = "loadpoint.boost"
    public static let opLoadpointSocSet = "loadpoint.soc.set"
    public static let opLoadpointSurplusOnlySet = "loadpoint.surplus_only.set"
    /// Cars (docs/cars.md in srcfl/ftw). A box offers them with `der.car`.
    public static let opCarGoalSet = "car.goal.set"
    public static let opCarSocSet = "car.soc.set"
    public static let opSessionCarSet = "session.car.set"
    public static let opCarAdd = "car.add"
    public static let opCarUpdate = "car.update"
    public static let opCarRemove = "car.remove"

    public static let ops = [
        opSetMode, opPlannerPrefsSet, opSiteTimeZonePropose, opBatteryHold, opLoadpointHold, opLoadpointBoost, opLoadpointSocSet, opLoadpointSurplusOnlySet,
        opCarGoalSet, opCarSocSet, opSessionCarSet, opCarAdd, opCarUpdate, opCarRemove,
    ]

    /// The scope that opens each op to an agent, from the registry's `agent`
    /// on each op. `ftw.dispatch.hold` runs as a `cmd` within the grant's
    /// caps; `ftw.goals.request` waits as an `agent.request` for an owner.
    /// An op not listed is never open to an agent.
    public static let agentOps: [String: String] = [
        opSetMode: "ftw.goals.request",
        opPlannerPrefsSet: "ftw.goals.request",
        opLoadpointHold: "ftw.dispatch.hold",
        opLoadpointSocSet: "ftw.goals.request",
        opLoadpointSurplusOnlySet: "ftw.goals.request",
        opCarGoalSet: "ftw.goals.request",
        opCarSocSet: "ftw.goals.request",
    ]

    /// Each op's description, from the registry.
    public static let opDescs: [String: String] = [
        opSetMode: "Change the site operating mode",
        opPlannerPrefsSet: "Set household planner preferences",
        opSiteTimeZonePropose: "Offer the phone's time zone to a box that keeps none",
        opBatteryHold: "Hold the battery at a fixed setpoint",
        opLoadpointHold: "Charge the car now at a fixed current",
        opLoadpointBoost: "Boost the car from the house battery",
        opLoadpointSocSet: "Correct the car's current charge level",
        opLoadpointSurplusOnlySet: "Charge the car from surplus PV only",
        opCarGoalSet: "Set how and when a car charges",
        opCarSocSet: "Set a car's level by hand",
        opSessionCarSet: "Say which car is on a charger",
        opCarAdd: "Add a car to the owner's list",
        opCarUpdate: "Change what the box knows about a car",
        opCarRemove: "Remove a car from the owner's list",
    ]

    /// One argument an agent may put in an op: the registry's `agent_args`.
    /// `label` is the words the app shows an owner for the value.
    public struct AgentArg: Equatable, Sendable {
        public var name: String
        public var kind: String
        public var unit: String?
        public var min: Double?
        public var max: Double?
        public var values: [String]
        public var required: Bool
        public var cap: String?
        public var label: String

        init(_ name: String, _ kind: String, unit: String? = nil, min: Double? = nil, max: Double? = nil, values: [String] = [], required: Bool = false, cap: String? = nil, label: String) {
            self.name = name
            self.kind = kind
            self.unit = unit
            self.min = min
            self.max = max
            self.values = values
            self.required = required
            self.cap = cap
            self.label = label
        }
    }

    public static let agentArgs: [String: [AgentArg]] = [
        opSetMode: [AgentArg("mode", "mode", required: true, label: "Operating mode")],
        opPlannerPrefsSet: [
            AgentArg("safety_k", "number", min: 0, max: 2, label: "How cautious the plan is"),
            AgentArg("battery_export", "enum", values: ["unknown", "not_allowed", "allowed"], label: "Whether the battery may sell to the grid"),
        ],
        opLoadpointHold: [
            AgentArg("id", "loadpoint", required: true, label: "Charger"),
            AgentArg("power_w", "power", unit: "W", min: 0, cap: "maxW", label: "Charging power"),
            AgentArg("hold_s", "duration", unit: "s", min: 1, cap: "holdS", label: "For how long"),
            AgentArg("phase_mode", "enum", values: ["auto", "1p", "3p"], label: "Phases"),
            AgentArg("clear", "bool", label: "Stop the agent's own hold"),
        ],
        opLoadpointSocSet: [
            AgentArg("id", "loadpoint", required: true, label: "Charger"),
            AgentArg("soc", "ratio", min: 0, max: 1, required: true, label: "The car's charge level"),
        ],
        opLoadpointSurplusOnlySet: [
            AgentArg("id", "loadpoint", required: true, label: "Charger"),
            AgentArg("surplus_only", "bool", required: true, label: "Charge from solar only"),
        ],
        opCarGoalSet: [
            AgentArg("id", "car", label: "Car"),
            AgentArg("charger_id", "loadpoint", label: "Charger"),
            AgentArg("target", "ratio", min: 0, max: 1, label: "The level to reach"),
            AgentArg("ready_by_min", "number", min: 0, max: 1439, label: "Ready by, in minutes after midnight"),
            AgentArg("days", "number", min: 0, max: 127, label: "Weekdays"),
            AgentArg("finish_at_limit", "bool", label: "Charge on to the car's own limit"),
            AgentArg("clear", "bool", label: "Remove the goal"),
            AgentArg("surplus_only", "bool", label: "Charge from solar only"),
        ],
        opCarSocSet: [
            AgentArg("id", "car", label: "Car"),
            AgentArg("charger_id", "loadpoint", label: "Charger"),
            AgentArg("soc", "ratio", min: 0, max: 1, required: true, label: "The car's charge level"),
        ],
    ]

    /// The box keeps cars apart from chargers. Absent, the charger is the
    /// car, as before.
    public static let capDerCar = "der.car"

    /// A car's names on the wire, from the registry's `car_fields`: a dotted
    /// name is a field of the object before the dot. The box spells each
    /// one in snake_case on its HTTP routes.
    public static let carFields = [
        "id", "boxMinted", "ownerId", "name", "make", "vin", "capacityWh", "maxW", "phases",
        "socPermille", "socSource", "socAgeS", "energySinceWh", "socEstimate", "chargeLimitPermille",
        "goal", "goal.targetPermille", "goal.readyByMin", "goal.days", "goal.finishAtLimit",
        "surplusOnly", "identifiers", "sources",
    ]
    /// Where a car's level comes from.
    public static let carSocSources = ["vehicle", "manual", "assumed"]
    /// How the box knows which car is on a charger. `asking` means the box
    /// raised `car.which` and waits for a tap.
    public static let carIdentifiedBy = ["charger", "car", "only", "tap", "asking", "none"]
    /// What a charger carries about the car on it.
    public static let chargerCarFields = ["session", "carId", "carIdentifiedBy", "carCorrected", "carCorrectedFrom", "choose"]

    /// The box's dispatch modes and where each is drawn. The box sends its
    /// own catalogue and is the authority on what exists; this copy is for
    /// validating and wording, never for deciding.
    public static let modes: [(key: String, tier: String)] = [
        ("planner_passive_arbitrage", "primary"),
        ("planner_arbitrage", "primary"),
        ("idle", "advanced"),
        ("self_consumption", "advanced"),
        ("peak_shaving", "advanced"),
        ("charge", "advanced"),
        ("planner_self", "hidden"),
        ("planner_cheap", "hidden"),
    ]

    /// Field ids frozen permanently as of v1.
    public enum FID {
        public static let mode = 1
        public static let gridW = 2
        public static let pvW = 3
        public static let batteryW = 4
        public static let batterySoc = 5
        public static let loadW = 6
        public static let srcGrid = 7
        public static let srcPV = 8
        public static let srcBattery = 9
        /// Present only on a site with a charger.
        public static let evW = 10

        /// The registry's extra fields: depth for a node's own view, sent
        /// only while the box has the reading. The grid's current on L1,
        /// L2 and L3 in tenths of an ampere, signed by the site convention,
        /// and the main fuse per phase as their scale.
        public static let gridL1DA = 11
        public static let gridL2DA = 12
        public static let gridL3DA = 13
        public static let gridFuseDA = 14
        public static let gridPhases = [gridL1DA, gridL2DA, gridL3DA]
    }

    /// Whether a code is worth retrying, from the registry's `errors` and
    /// `client_errors`. Unknown codes are not: guessing yes offers a button
    /// that cannot help.
    static let retryable: [String: Bool] = [
        "E_BOOTING": true,
        "E_UNKNOWN_OP": false,
        "E_CMD_EXPIRED": false,
        "E_PRECONDITION": false,
        "E_CONFLICT": true,
        "E_SCOPE_DENIED": false,
        "E_GRANT_REVOKED": false,
        "E_LAST_OWNER_PROTECTED": false,
        "E_RANGE_TOO_LARGE": false,
        "E_UNAVAILABLE": true,
        "E_NEEDS_STEP_UP": true,
        "E_USE_CMD": false,
        "E_UNSUPPORTED_MEDIA": false,
        "E_WHOLE_DOCUMENT": false,
        "E_LOCAL_ONLY": false,
        "E_GRANT_EXPIRED": false,
        "E_OP_NOT_GRANTED": false,
        "E_CAP_EXCEEDED": false,
        "E_RATE_LIMITED": true,
        "E_NEEDS_OWNER": false,
        "E_BAD_SIGNATURE": false,
        "E_NO_APPROVAL_KEY": false,
        "E_NOT_FOUND": false,
        "E_CLOCK_SKEW": true,
        "E_DUPLICATE": false,
        "E_RESPONSE_TOO_LARGE": false,
        "E_NO_ACK": true,
        "E_NO_ANSWER": true,
        "E_BAD_BODY": false,
    ]

    public static func isRetryable(_ code: String) -> Bool {
        retryable[code] ?? false
    }

    public static let sourceStates = ["live", "lagging", "stale", "down", "never"]
    public static let carrierStates = ["webrtc", "relay", "tunnel", "cloud", "cache", "none"]
    /// How the session with FTW Cloud travels, under `tunnel` and `cloud`.
    public static let cloudTransports = ["quic", "websocket"]
    public static let transportQUIC = "quic"
    public static let transportWebSocket = "websocket"
}
