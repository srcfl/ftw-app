import Foundation
import Testing
@testable import FTWKit

/// Source & licenses and removing this phone: what the license asks the app
/// to offer, and the words it uses to offer it.
@Suite struct AboutTests {
    static let sha = "5a14ff0960d99fa0ca982c82fb2b7c1d5e213d25"

    // MARK: The build's source

    @Test func aCleanCommitPinsBothLinks() {
        let source = BuildSource(version: "0.1.0", build: "7", recorded: Self.sha + "\n")
        #expect(source.revision == .commit(Self.sha))
        #expect(source.sourceURL.absoluteString == "https://github.com/srcfl/ftw-app/tree/\(Self.sha)")
        #expect(source.licenseURL.absoluteString == "https://github.com/srcfl/ftw-app/blob/\(Self.sha)/LICENSE")
        #expect(source.documentBaseURL.absoluteString == "https://github.com/srcfl/ftw-app/blob/\(Self.sha)/")
        #expect(source.versionText == "0.1.0 (7)")
        #expect(source.revisionText == "5a14ff0")
        #expect(source.localNote == nil)
    }

    @Test func uncommittedChangesAreALocalBuildOnTheirBase() {
        let source = BuildSource(version: "0.1.0", build: "1", recorded: Self.sha + "-dirty")
        #expect(source.revision == .local(base: Self.sha))
        #expect(source.isLocal)
        #expect(source.sourceURL == Origin.sourceURL)
        #expect(source.licenseURL.absoluteString == "https://github.com/srcfl/ftw-app/blob/main/LICENSE")
        AboutWords.$language.withValue(.en) {
            #expect(source.revisionText == "Local build")
            #expect(source.localNote?.contains("5a14ff0") == true)
        }
        AboutWords.$language.withValue(.sv) {
            #expect(source.revisionText == "Lokalt bygge")
        }
    }

    /// Only 40 lower-case hex digits name a commit. Anything else, including
    /// nothing at all, links to the repository and says so.
    @Test(arguments: [nil, "", "dev", "5a14ff0", Self.sha.uppercased(), Self.sha + "0", "g" + Self.sha.dropFirst(), "-dirty"])
    func anythingElseIsALocalBuild(_ recorded: String?) {
        let source = BuildSource(version: "0.1.0", build: "1", recorded: recorded)
        #expect(source.revision == .local(base: nil))
        #expect(source.sourceURL == Origin.sourceURL)
        #expect(source.localNote != nil)
    }

    /// App Review asks for the privacy policy inside the app. The pages are
    /// srcfl/ftw-web's, in English and Swedish.
    @Test func privacyAndSupportFollowTheLanguage() {
        #expect(Origin.privacyURL(.en).absoluteString == "https://ftw.energy/privacy")
        #expect(Origin.privacyURL(.sv).absoluteString == "https://ftw.energy/sv/privacy")
        #expect(Origin.supportURL(.en).absoluteString == "https://ftw.energy/support")
        #expect(Origin.supportURL(.sv).absoluteString == "https://ftw.energy/sv/support")
        AboutWords.$language.withValue(.sv) {
            #expect(Origin.privacyURL() == Origin.privacyURL(.sv))
        }
    }

    // MARK: The license files

    /// Joining lines must never change the text: every word of every file,
    /// in order, and nothing else.
    @Test(arguments: LicenseText.Document.allCases)
    func reflowKeepsEveryWord(_ document: LicenseText.Document) throws {
        let text = try RepoFiles.read(document.rawValue)
        let blocks = LicenseText.blocks(text, markdown: document.isMarkdown)
        let original = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !LicenseText.isRule($0) }
            .map { document.isMarkdown ? $0.replacingOccurrences(of: #"^#{1,6} "#, with: "", options: .regularExpression) : $0 }
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
        let shown = blocks.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
        #expect(shown == original)
        #expect(!blocks.isEmpty)
    }

    @Test func theLicenseReadsAsParagraphsAndSections() throws {
        let blocks = LicenseText.blocks(try RepoFiles.read("LICENSE"), markdown: false)
        // The heading over the file stays two lines.
        #expect(blocks.first?.text == "FTW native app\nCopyright 2026 Sourceful Labs AB and contributors.")
        // A wrapped paragraph becomes one line the screen wraps itself.
        let opening = try #require(blocks.first { $0.text.hasPrefix("This version of the project, as a whole") })
        #expect(!opening.text.contains("\n"))
        #expect(blocks.contains { $0.kind == .heading(2) && $0.text == "0. Definitions." })
        #expect(blocks.contains { $0.kind == .heading(1) && $0.text == "TERMS AND CONDITIONS" })
        #expect(blocks.contains { $0.kind == .heading(1) && $0.text == "GNU AFFERO GENERAL PUBLIC LICENSE\nVersion 3, 19 November 2007" })
        #expect(blocks.contains { $0.kind == .rule })
        // Both of the license's own permissions are there.
        #expect(blocks.contains { $0.text.contains("FTW app store distribution permission") } || blocks.contains { $0.text.contains("Energyplan") })
        // A list keeps one item to a line.
        let items = blocks.filter { $0.text.contains("\n- ") }
        for block in items {
            for line in block.text.split(separator: "\n").dropFirst() {
                #expect(!line.hasPrefix(" "))
            }
        }
    }

    @Test func licensingMarkdownHasItsHeadings() throws {
        let blocks = LicenseText.blocks(try RepoFiles.read("LICENSING.md"), markdown: true)
        #expect(blocks.first == LicenseText.Block(id: 0, kind: .heading(1), text: "FTW native app licensing"))
        #expect(blocks.contains { $0.kind == .heading(2) && $0.text == "Source for a distributed version" })
        #expect(!blocks.contains { $0.text.hasPrefix("#") })
    }

    @Test func relativeLinksOpenTheFileAtTheBuildsCommit() throws {
        let source = BuildSource(version: "0.1.0", build: "1", recorded: Self.sha)
        let text = LicenseText.inline("See [LICENSE](LICENSE) and [the vision](https://github.com/srcfl/ftw/blob/master/VISION.md).", base: source.documentBaseURL)
        let links = text.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://github.com/srcfl/ftw-app/blob/\(Self.sha)/LICENSE", "https://github.com/srcfl/ftw/blob/master/VISION.md"])
        #expect(String(text.characters) == "See LICENSE and the vision.")
    }

    @Test func listsAndShortLinesKeepTheirBreaks() {
        let text = """
        All other conditions of the GNU AGPL remain in force. In particular:

        - Offer the Corresponding Source of the exact version you convey, under the
          GNU AGPL and at no charge, outside the service and free of its terms.
        - Make the license text and that source offer reachable from within the
          program.
        """
        let blocks = LicenseText.blocks(text, markdown: false)
        #expect(blocks.count == 2)
        #expect(blocks[1].text == "- Offer the Corresponding Source of the exact version you convey, under the GNU AGPL and at no charge, outside the service and free of its terms.\n- Make the license text and that source offer reachable from within the program.")
    }

    // MARK: Third-party code

    /// Source & licenses says FTW carries no third-party code. That stays
    /// true only while neither the package nor the project pulls any in; add
    /// one and this fails until the screen lists it with its license.
    @Test func thereIsNoThirdPartyCode() throws {
        let package = try RepoFiles.read("appleApp/FTWKit/Package.swift")
        #expect(!package.contains(".package("))
        let project = try RepoFiles.read("appleApp/FTW.xcodeproj/project.pbxproj")
        #expect(!project.contains("XCRemoteSwiftPackageReference"))
    }

    // MARK: Removing this phone

    @Test func theBoxNamesThePhoneByItsKey() throws {
        let vectors = try IdentityVectors.load()
        let name = PhoneRemoval.nameOnBox(vectors.enrollment.deviceIdOnBox)
        #expect(name == "Phone \(vectors.enrollment.deviceIdOnBox)")
        AboutWords.$language.withValue(.en) {
            #expect(PhoneRemoval.boxSteps("abcd1234").last == "Choose Remove next to Phone abcd1234.")
        }
        AboutWords.$language.withValue(.sv) {
            #expect(PhoneRemoval.boxSteps("abcd1234").last == "Välj Remove bredvid Phone abcd1234.")
        }
    }

    @MainActor
    @Test func theNameOnTheBoxIsTheVaultsOwn() async throws {
        let store = MemoryStore()
        let vault = Vault(store: store)
        #expect(vault.deviceIDOnBox == nil)
        _ = try vault.deviceKey(vault.localWrappingKey())
        let id = try #require(vault.deviceIDOnBox)
        #expect(id.count == Vault.boxDeviceIDChars)
        #expect(PhoneRemoval.nameOnBox(id).hasSuffix(id))
    }

    // MARK: Words

    /// Every sentence the About screens hand to `AboutWords` has a Swedish
    /// entry. Read from the source, so a new sentence cannot slip through.
    @Test func everySentenceHasSwedish() throws {
        let files = [
            "appleApp/FTWKit/Sources/FTWKit/Identity/BuildSource.swift",
            "appleApp/FTWKit/Sources/FTWKit/Identity/LicenseText.swift",
            "appleApp/FTWKit/Sources/FTWKit/Identity/PhoneRemoval.swift",
        ] + (try RepoFiles.list("appleApp/FTW/About"))
        let pattern = #/AboutWords\.(?:text|format)\("((?:[^"\\]|\\.)*)"/#
        var seen = 0
        for file in files {
            let source = try RepoFiles.read(file)
            for match in source.matches(of: pattern) {
                let english = String(match.1).replacingOccurrences(of: "\\\"", with: "\"")
                seen += 1
                #expect(AboutWords.sv[english] != nil, "no Swedish for \"\(english)\" in \(file)")
            }
        }
        #expect(seen > 20)
        for (english, swedish) in AboutWords.sv {
            #expect(!swedish.isEmpty)
            #expect(english.components(separatedBy: "%@").count == swedish.components(separatedBy: "%@").count, "\(english)")
        }
    }
}

extension RepoFiles {
    /// The Swift files in a folder of the repository, as paths from its root.
    static func list(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .map { "\(folder)/\($0)" }
    }
}
