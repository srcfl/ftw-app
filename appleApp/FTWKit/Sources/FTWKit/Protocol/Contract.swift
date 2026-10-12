import Foundation

/// Names from protocol/registry.yaml, in Swift.
///
/// The registry is one file shared byte for byte with srcfl/ftw and
/// srcfl/ftw-webapp. There is no generator here, so this is written by hand
/// and `ContractTests` reads the registry back and fails when anything has
/// stopped matching. Add nothing here that is not in the registry.
public enum Contract {
    /// One object axis, two verb axes: `<object>.<read|write>`.
    public static let scopes = [
        "ftw.live.read",
        "ftw.history.read",
        "ftw.plan.read",
        "ftw.health.read",
        "ftw.assets.read",
        "ftw.dispatch.write",
        "ftw.mode.write",
        "ftw.members.read",
        "ftw.members.write",
    ]

    public static let roleOwner = "owner"
    public static let roleViewer = "viewer"

    /// What each role carries, with the registry's `*` expanded. Used only
    /// for a box from before roles, which sends no scope list.
    public static let roleScopes: [String: [String]] = [
        roleOwner: scopes,
        roleViewer: ["ftw.live.read"],
    ]

    public static let roleLabels: [String: String] = [
        roleOwner: "Owner",
        roleViewer: "Viewer",
    ]

    public static let scopeModeWrite = "ftw.mode.write"

    public static let capabilities = [
        "status.core", "status.phases", "status.drivers",
        "history.5m", "history.1h", "history.etag",
        "cmd.lease", "cmd.precondition", "cmd.readback",
        "der.battery", "der.ev", "der.v2x",
        "plan.dispatch", "net.webrtc", "price.spot", "api.passthrough",
    ]

    public static let capPlanDispatch = "plan.dispatch"
    public static let capDerEV = "der.ev"
    public static let capPriceSpot = "price.spot"
    public static let capAPIPassthrough = "api.passthrough"

    public static let opSetMode = "site.mode.set"
    public static let opBatteryHold = "battery.hold"
    public static let opLoadpointHold = "loadpoint.hold"
    public static let opLoadpointBoost = "loadpoint.boost"
    public static let opLoadpointSocSet = "loadpoint.soc.set"
    public static let opLoadpointSurplusOnlySet = "loadpoint.surplus_only.set"

    public static let ops = [opSetMode, opBatteryHold, opLoadpointHold, opLoadpointBoost, opLoadpointSocSet, opLoadpointSurplusOnlySet]

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
        "E_RESPONSE_TOO_LARGE": false,
        "E_NO_ACK": true,
        "E_NO_ANSWER": true,
        "E_BAD_BODY": false,
    ]

    public static func isRetryable(_ code: String) -> Bool {
        retryable[code] ?? false
    }

    public static let sourceStates = ["live", "lagging", "stale", "down", "never"]
    public static let carrierStates = ["webrtc", "relay", "cache", "none"]
}
