import Foundation

/// What this build was made from, and where its source is.
///
/// The AGPL and the app store permission in LICENSE ask that the license and
/// an offer of the exact version's source be reachable in the app. The build
/// writes its commit into the bundle (the "Record the source revision" phase
/// in the Xcode project), and this turns that record into the links and the
/// words Source & licenses shows.
public struct BuildSource: Equatable, Sendable {
    public enum Revision: Equatable, Sendable {
        /// A clean tree at a known commit. The links pin it.
        case commit(String)
        /// Uncommitted changes on top of `base`, or no commit known at all.
        /// The links go to the repository, which may not hold this code.
        case local(base: String?)
    }

    public let version: String
    public let build: String
    public let revision: Revision

    /// What the build phase wrote: 40 hex digits for a clean tree, the same
    /// with `-dirty` for uncommitted changes, and nothing when no commit was
    /// known. Anything else is a local build too.
    public init(version: String, build: String, recorded: String?) {
        self.version = version
        self.build = build
        let text = (recorded ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isCommit(text) {
            revision = .commit(text)
        } else if text.hasSuffix(Self.dirtySuffix), Self.isCommit(String(text.dropLast(Self.dirtySuffix.count))) {
            revision = .local(base: String(text.dropLast(Self.dirtySuffix.count)))
        } else {
            revision = .local(base: nil)
        }
    }

    static let dirtySuffix = "-dirty"

    static func isCommit(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    public var commit: String? {
        if case .commit(let sha) = revision { return sha }
        return nil
    }

    public var isLocal: Bool { commit == nil }

    /// Seven characters, as GitHub shows a commit.
    public static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    /// The tree at this commit, whose Code menu offers the archive. A local
    /// build gets the repository.
    public var sourceURL: URL {
        guard let commit else { return Origin.sourceURL }
        return Origin.sourceURL.appending(path: "tree/\(commit)")
    }

    /// The license as it stood at this commit, not on the moving branch.
    public var licenseURL: URL {
        Origin.sourceURL.appending(path: "blob/\(commit ?? "main")/LICENSE")
    }

    /// Where a relative link in LICENSING.md points, at the same revision.
    public var documentBaseURL: URL {
        Origin.sourceURL.appending(path: "blob/\(commit ?? "main")/")
    }

    /// "0.1.0 (1)", as Settings shows an app's version.
    public var versionText: String { "\(version) (\(build))" }

    /// The commit as the screen names it.
    public var revisionText: String {
        switch revision {
        case .commit(let sha): return Self.short(sha)
        case .local: return AboutWords.text("Local build")
        }
    }

    /// Why the links do not pin this build, or nil when they do.
    public var localNote: String? {
        switch revision {
        case .commit: return nil
        case .local(let base?):
            return AboutWords.format("Built from uncommitted changes on top of %@. The links go to the repository, which does not hold these changes.", Self.short(base))
        case .local(nil):
            return AboutWords.text("Built without a known commit. The links go to the repository, which may not hold this exact code.")
        }
    }
}
