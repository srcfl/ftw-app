import Foundation
import Testing

/// The app's palette, read from `FTWCharts/Theme.xcassets`, the one source
/// the app and the widgets draw with. Text reaches 4.5:1 on every surface
/// it sits on, in light and dark; an energy colour reads as a word in light
/// and as a stroke without its glow in dark; Increase Contrast only ever
/// raises it; and no orange is left.
@Suite struct ThemeTests {
    struct RGB: Equatable { let r, g, b: Double; let p3: Bool }

    enum Look: CaseIterable { case light, dark, lightHigh, darkHigh }

    static let catalog = "appleApp/FTWCharts/Theme.xcassets"
    static let roles = ["ground", "raised", "hairline", "ink", "ink2", "ink3", "solar", "gives", "stores", "grid", "car", "live", "alarm"]
    static let energy = ["solar", "gives", "stores", "grid", "car"]

    /// One colour set, by look. A look the set does not name falls back the
    /// way the asset catalogue does: high contrast to normal, dark to light.
    func color(_ role: String, _ look: Look, in path: String? = nil) throws -> RGB {
        let text = try RepoFiles.read(path ?? "\(Self.catalog)/ftw.\(role).colorset/Contents.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        var byLook: [Set<String>: RGB] = [:]
        for c in colors {
            let marks = Set(((c["appearances"] as? [[String: String]]) ?? []).compactMap { $0["value"] })
            let color = try #require(c["color"] as? [String: Any])
            let comps = try #require(color["components"] as? [String: String])
            func channel(_ k: String) throws -> Double {
                let v = try #require(comps[k])
                return v.hasPrefix("0x") ? Double(Int(v.dropFirst(2), radix: 16) ?? 0) / 255 : (Double(v) ?? 0)
            }
            byLook[marks] = RGB(r: try channel("red"), g: try channel("green"), b: try channel("blue"), p3: color["color-space"] as? String == "display-p3")
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

    /// Relative luminance, with the primaries of the colour's own space.
    func luminance(_ c: RGB) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.040_45 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let k = c.p3 ? (0.228_975, 0.691_739, 0.079_287) : (0.2126, 0.7152, 0.0722)
        return k.0 * lin(c.r) + k.1 * lin(c.g) + k.2 * lin(c.b)
    }

    func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func ratio(_ role: String, on surface: String, _ look: Look) throws -> Double {
        contrast(try color(role, look), try color(surface, look))
    }

    /// Display P3, with a light and a dark colour, for every role.
    @Test(arguments: ThemeTests.roles)
    func everyRoleIsDisplayP3InLightAndDark(_ role: String) throws {
        let light = try color(role, .light), dark = try color(role, .dark)
        #expect(light.p3 && dark.p3, "\(role) is not authored in Display P3")
        #expect(light != dark, "\(role) has no dark variant")
    }

    /// Ink, ink2 and ink3 are text: 4.5:1 on the ground and on raised rows,
    /// in every look.
    @Test(arguments: ["ink", "ink2", "ink3"])
    func textReadsOnEverySurface(_ role: String) throws {
        for look in Look.allCases {
            for surface in ["ground", "raised"] {
                let r = try ratio(role, on: surface, look)
                #expect(r >= 4.5, "\(role) on \(surface), \(look): \(String(format: "%.2f", r)):1")
            }
        }
    }

    /// An energy colour reads as a word on paper, and in dark its stroke
    /// alone carries 7:1, so the glow is extra and sunlight cannot erase a
    /// reading. Live and alarm read as words in both.
    @Test(arguments: ThemeTests.energy + ["live", "alarm"])
    func energyAndStatesRead(_ role: String) throws {
        let light = try ratio(role, on: "ground", .light)
        let dark = try ratio(role, on: "ground", .dark)
        #expect(light >= 4.5, "\(role) in light: \(String(format: "%.2f", light)):1")
        #expect(dark >= (Self.energy.contains(role) ? 7 : 4.5), "\(role) in dark: \(String(format: "%.2f", dark)):1")
    }

    /// Increase Contrast turns ink3 into ink2, and raises it on every
    /// surface.
    @Test func increaseContrastMakesInk3Ink2() throws {
        for (normal, high) in [(Look.light, Look.lightHigh), (.dark, .darkHigh)] {
            #expect(try color("ink3", high) == color("ink2", normal))
            for surface in ["ground", "raised"] {
                #expect(try ratio("ink3", on: surface, high) > ratio("ink3", on: surface, normal))
            }
        }
    }

    /// The system tint is ink and the launch screen is the ground, in the
    /// app's own catalog, which the system reads before any view.
    @Test func theTintIsInkAndTheLaunchIsTheGround() throws {
        for look in [Look.light, .dark] {
            #expect(try color("", look, in: "appleApp/FTW/Assets.xcassets/AccentColor.colorset/Contents.json") == color("ink", look))
            #expect(try color("", look, in: "appleApp/FTW/Assets.xcassets/LaunchBackground.colorset/Contents.json") == color("ground", look))
        }
    }

    /// The app, its icon, the widgets and the charts they share: no 0.3
    /// orange in any colour set or file, and no colour written in code. Colours live in the
    /// catalog, so a widget can never drift from the app.
    @Test func noOrangeAndNoColourInCode() throws {
        let orange: Set<String> = ["DA7F00", "FFAC41"]
        for folder in ["appleApp/FTW", "appleApp/FTWCharts", "appleApp/FTWWidgets", "appleApp/FTWNotify"] {
            let root = RepoFiles.root.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files {
                let name = url.lastPathComponent
                guard ["swift", "json", "svg"].contains(url.pathExtension) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let shown = url.path.replacingOccurrences(of: RepoFiles.root.path + "/", with: "")
                for hex in orange {
                    #expect(!text.uppercased().contains(hex), "\(shown) holds #\(hex)")
                }
                if name == "Contents.json", text.contains("\"components\"") {
                    for look in [Look.light, .dark, .lightHigh, .darkHigh] {
                        let c = try color("", look, in: shown)
                        let hex = String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
                        #expect(!orange.contains(hex), "\(shown) is #\(hex) in \(look)")
                    }
                }
                if url.pathExtension == "swift" {
                    #expect(!text.contains("Color(red:"), "\(shown) writes a colour in code")
                    #expect(text.firstMatch(of: /Pair\(0x/) == nil, "\(shown) writes a colour in code")
                }
            }
        }
    }
}
