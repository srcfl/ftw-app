import Foundation

/// Sentences for a command's fate. One table for every op: the codes are
/// about the door, not about what was asked.
public enum CommandText {
    public static func help(_ r: CmdResult) -> String {
        switch r.errorCode {
        case "E_PRECONDITION": return "Your home changed while that was sending. Have another go."
        case "E_CONFLICT": return "Something else changed the setting first. Try again."
        case "E_SCOPE_DENIED": return "You don't have permission to change how this home runs."
        case "E_CMD_EXPIRED": return "That took too long to reach your box. Try again."
        case "E_BOOTING": return "Your box is still starting. Give it a minute."
        case "E_UNAVAILABLE":
            if r.errorArgs["op"]?.string == Contract.opLoadpointSurplusOnlySet { return "Solar rule not saved. Your previous choice is unchanged. Try again." }
            return "Your box can't reach the charger right now. Try again shortly."
        default: return "That didn't go through. Try again."
        }
    }

    /// The boost's own refusals before the door's.
    public static func boostHelp(_ r: CmdResult) -> String {
        if r.errorCode == "E_UNAVAILABLE", r.errorArgs["op"]?.string != nil {
            return "Your box won't boost right now — the house battery or the site isn't ready for it."
        }
        if r.errorCode == "E_UNKNOWN_OP", r.errorArgs["arg"]?.string == "lease" {
            return "Your box refused that reserve and time. Try other values."
        }
        return help(r)
    }

    /// A level for a car that is not on the cable is refused by name.
    public static func socHelp(_ r: CmdResult) -> String {
        if r.errorCode == "E_UNAVAILABLE", r.errorArgs["reason"]?.string == "unplugged" {
            return "Plug the car in first — your box has no car to set a level for."
        }
        return help(r)
    }
}
