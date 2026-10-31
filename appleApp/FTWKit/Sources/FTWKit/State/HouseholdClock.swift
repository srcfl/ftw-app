import Foundation

/// The zone the phone offers its box as the household clock.
///
/// A Docker box runs on UTC whatever house it is in, so a car goal of 17:00
/// was met at 18:00 in a Stockholm winter. The phone offers its own zone to a
/// box that says UTC; the box decides, and takes it only while it keeps none.
public enum HouseholdClock {
    /// Names that mean UTC. A box that says one keeps no household clock; a
    /// phone that says one knows nothing about the house.
    static let utcNames: Set<String> = ["UTC", "UCT", "GMT", "GMT0", "GMT+0", "GMT-0", "Greenwich", "Universal", "Zulu"]

    public static func isUTC(_ zone: String) -> Bool {
        let name = zone.trimmingCharacters(in: .whitespaces)
        return utcNames.contains(name.hasPrefix("Etc/") ? String(name.dropFirst(4)) : name)
    }

    /// The zone to offer, or nil: only to a box on UTC, from a phone on a
    /// zone of its own that may change setup.
    public static func zoneToOffer(boxTZ: String?, phoneTZ: String?, scopes: Set<String>) -> String? {
        guard let boxTZ, isUTC(boxTZ), let phoneTZ, !phoneTZ.isEmpty, !isUTC(phoneTZ),
              scopes.contains(AccessWire.scopeSetup) else { return nil }
        return phoneTZ
    }
}
