import Foundation

/// The license files as a phone reads them.
///
/// The files are wrapped at about 72 columns for a terminal. Shown as they
/// are, every line breaks twice on a phone: once where the file breaks it and
/// once where the screen does. This joins the lines of a paragraph and keeps
/// every word in order; it changes line breaks, never text.
public enum LicenseText {
    /// The three files the build copies into the app from the repository
    /// root. Nothing here is a copy that could drift from the original.
    public enum Document: String, CaseIterable, Sendable, Identifiable {
        case license = "LICENSE"
        case notice = "NOTICE"
        case licensing = "LICENSING.md"

        public var id: String { rawValue }

        public var isMarkdown: Bool { self == .licensing }

        public var title: String {
            switch self {
            case .license: return AboutWords.text("License")
            case .notice: return AboutWords.text("Notices")
            case .licensing: return AboutWords.text("Licensing in plain words")
            }
        }
    }

    public struct Block: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            /// 1 is a document's title, 2 a section.
            case heading(Int)
            case paragraph
            /// A line of dashes or equals signs between parts.
            case rule
        }

        public let id: Int
        public let kind: Kind
        /// Lines that start a list item or end short in the file keep their
        /// break as "\n". Every other break is a space.
        public let text: String
    }

    public static func blocks(_ text: String, markdown: Bool) -> [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // The column the file wraps at, so a line that ends well short of it
        // is known to end there on purpose.
        let width = min(80, lines.map(\.count).max() ?? 0)
        var out: [Block] = []
        var paragraph: [String] = []

        func add(_ kind: Block.Kind, _ text: String) {
            out.append(Block(id: out.count, kind: kind, text: text))
        }

        func flush() {
            guard !paragraph.isEmpty else { return }
            defer { paragraph = [] }
            if !markdown, paragraph.count == 1, let level = plainHeading(paragraph[0]) {
                add(.heading(level), paragraph[0].trimmingCharacters(in: .whitespaces))
                return
            }
            // A title block: lines set in the middle of the page, or a
            // name in capitals over a short line, such as the license's
            // name over its version.
            let titled = paragraph.count == 2 && plainHeading(paragraph[0]) == 1 && paragraph[1].trimmingCharacters(in: .whitespaces).count <= 40
            if !markdown, paragraph.count > 1, titled || paragraph.allSatisfy(isCentred) {
                add(.heading(1), paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
                return
            }
            add(.paragraph, join(paragraph, width: width))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if isRule(trimmed) {
                flush()
                add(.rule, "")
            } else if markdown, let (level, title) = markdownHeading(trimmed) {
                flush()
                add(.heading(level), title)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// A Markdown paragraph with its links made absolute against `base`, so
    /// LICENSING.md's `[LICENSE](LICENSE)` opens the file at the build's
    /// commit rather than nowhere. Plain text when it does not parse.
    public static func inline(_ text: String, base: URL) -> AttributedString {
        guard var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace), baseURL: base) else {
            return AttributedString(text)
        }
        for run in out.runs {
            if let link = run.link {
                out[run.range].link = link.absoluteURL
            }
        }
        return out
    }

    /// Joins a paragraph's lines. A line keeps its break when the next one
    /// starts a list item, or when it ends well short of the wrap column,
    /// as an address or a title over a line does.
    static func join(_ lines: [String], width: Int) -> String {
        var out = ""
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if i > 0 {
                let short = lines[i - 1].count < width - 20
                out += startsItem(line) || short ? "\n" : " "
            }
            out += line
        }
        return out
    }

    static func startsItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
            || line.range(of: #"^(\(?[a-z0-9]{1,3}\)|[0-9]{1,2}\.) "#, options: .regularExpression) != nil
    }

    static func isRule(_ line: String) -> Bool {
        line.count >= 3 && Set(line).count == 1 && (line.first == "-" || line.first == "=" || line.first == "_")
    }

    static func markdownHeading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (min(hashes, 2), String(line.dropFirst(hashes + 1)))
    }

    static func isCentred(_ line: String) -> Bool {
        line.prefix(while: { $0 == " " }).count >= 8 && line.trimmingCharacters(in: .whitespaces).count <= 60
    }

    /// In plain text a title is a line on its own: set in capitals, centred
    /// with spaces, or a numbered section such as "0. Definitions."
    static func plainHeading(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 60 else { return nil }
        let letters = trimmed.filter(\.isLetter)
        if !letters.isEmpty, letters == letters.uppercased(), letters.count >= 4 { return 1 }
        if isCentred(line) { return 1 }
        if trimmed.range(of: #"^[0-9]{1,2}\. [A-Z][^.]*\.$"#, options: .regularExpression) != nil { return 2 }
        return nil
    }
}
