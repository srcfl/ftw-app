import Foundation
import Testing

/// The app's colour roles, read from `Theme.xcassets`, keep text readable:
/// every role drawn as text reaches 4.5:1 on every surface it sits on, in
/// light and dark, and Increase Contrast only ever raises it.
@Suite struct ThemeTests {
    struct RGB { let r, g, b: Double }

    enum Look: CaseIterable { case light, dark, lightHigh, darkHigh }

    /// One colour set, by look. A look the set does not name falls back the
    /// way the asset catalogue does: high contrast to normal, dark to light.
    func color(_ role: String, _ look: Look) throws -> RGB {
        let text = try RepoFiles.read("appleApp/FTW/UI/Theme.xcassets/\(role).colorset/Contents.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        var byLook: [Set<String>: RGB] = [:]
        for c in colors {
            let marks = Set(((c["appearances"] as? [[String: String]]) ?? []).compactMap { $0["value"] })
            let comps = try #require((c["color"] as? [String: Any])?["components"] as? [String: String])
            func channel(_ k: String) throws -> Double {
                let v = try #require(comps[k])
                return v.hasPrefix("0x") ? Double(Int(v.dropFirst(2), radix: 16) ?? 0) / 255 : (Double(v) ?? 0)
            }
            byLook[marks] = RGB(r: try channel("red"), g: try channel("green"), b: try channel("blue"))
        }
        let wanted: [Set<String>]
        switch look {
        case .light: wanted = [[]]
        case .dark: wanted = [["dark"], []]
        case .lightHigh: wanted = [["high"], []]
        case .darkHigh: wanted = [["dark", "high"], ["dark"], []]
        }
        return try #require(wanted.lazy.compactMap { byLook[$0] }.first, "\(role) has no colour for \(look)")
    }

    func luminance(_ c: RGB) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.039_28 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static let surfaces = ["ftw.surface", "ftw.surfaceRaised", "ftw.surfaceSunken", "ftw.surfaceElevated"]

    @Test(arguments: ["ftw.fg", "ftw.fgDim", "ftw.fgMuted", "ftw.accent"])
    func textReadsOnEverySurface(_ role: String) throws {
        for look in Look.allCases {
            for surface in Self.surfaces {
                let ratio = contrast(try color(role, look), try color(surface, look))
                #expect(ratio >= 4.5, "\(role) on \(surface), \(look): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    /// Increase Contrast makes the text roles stronger, never weaker.
    @Test(arguments: ["ftw.fgDim", "ftw.fgMuted", "ftw.accent", "ftw.accentFill"])
    func increaseContrastRaisesIt(_ role: String) throws {
        for (normal, high) in [(Look.light, Look.lightHigh), (.dark, .darkHigh)] {
            for surface in Self.surfaces {
                let before = contrast(try color(role, normal), try color(surface, normal))
                let after = contrast(try color(role, high), try color(surface, high))
                #expect(after > before, "\(role) on \(surface): \(before) → \(after)")
            }
        }
    }

    /// The fill keeps the brand orange; the text role is its darker sibling
    /// in light and the same colour in dark, where the orange already reads.
    @Test func theFillIsTheBrandOrange() throws {
        let fill = try color("ftw.accentFill", .light)
        #expect(Int((fill.r * 255).rounded()) == 0xDA && Int((fill.g * 255).rounded()) == 0x7F && fill.b == 0)
        let text = try color("ftw.accent", .light)
        #expect(luminance(text) < luminance(fill))
    }
}
