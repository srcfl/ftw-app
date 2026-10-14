import FTWShared
import os
import SwiftUI
import WidgetKit

let log = Logger(subsystem: "energy.ftw.app.watchkitapp", category: "complications")

/// The watch's complications and its Smart Stack card. Like the phone's
/// widgets they read the records in the App Group and nothing else: the
/// watch app leaves there what the phone handed over. They never glow, and
/// every one says how old its plan or price is.
@main
struct FTWWatchWidgets: WidgetBundle {
    var body: some Widget {
        PlanComplication()
        CheapPowerWidget()
    }
}

/// The records as the watch app last kept them, for the home it shows.
enum Kept {
    static func read() -> (plan: CacheRead<PlanEntry>?, prices: CacheRead<PriceEntry>?, now: CacheRead<WatchNow>?) {
        guard let reader = CacheReader.shared() else {
            log.error("no App Group, nothing to read")
            return (nil, nil, nil)
        }
        let site = reader.latestSiteID(PlanEntry.self) ?? reader.latestSiteID(PriceEntry.self)
        guard let site else { return (nil, nil, nil) }
        return (reader.read(PlanEntry.self, siteId: site), reader.read(PriceEntry.self, siteId: site), reader.read(WatchNow.self, siteId: site))
    }
}
