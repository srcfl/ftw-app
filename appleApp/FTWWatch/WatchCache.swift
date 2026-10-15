import Foundation
import FTWShared
import WidgetKit

/// The watch's own copy of the last truth: the whole context it last had,
/// with the last minutes of Now's trace, so it opens on it with no phone
/// near, and the records its complications read. Kept in this watch's App Group, which stays on the
/// watch. Each record keeps the time it was read, so what opens from here
/// is dated and never glows.
struct WatchCache: Sendable {
    let files: AppGroupFiles

    static func shared() -> WatchCache? { AppGroupFiles.shared().map(WatchCache.init) }

    private var url: URL { files.directory.appendingPathComponent("watch-context") }

    func load() -> WatchContext? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return WatchContext.unpacked(data)
    }

    /// Keep `ctx`. Only a sign-out forgets everything; a context with no
    /// home that does not say so never reaches here (`WatchContext.merging`).
    func save(_ ctx: WatchContext) async {
        if ctx.signedOut == true {
            files.removeAll()
            reload()
            return
        }
        guard ctx.hasHome else { return }
        let asked = files.clearCount
        do {
            if let r = ctx.prices { _ = try await files.write(r, asked: asked) }
            if let r = ctx.plan { _ = try await files.write(r, asked: asked) }
            if let r = ctx.cars { _ = try await files.write(r, asked: asked) }
            if let r = ctx.now { _ = try await files.write(r, asked: asked) }
            guard files.clearCount == asked else { return }
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            try ctx.packed().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            reload()
        } catch {
            WatchModel.log.error("could not keep the last context: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reload() {
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.invalidateRelevance(ofKind: WatchKinds.cheap)
    }
}
