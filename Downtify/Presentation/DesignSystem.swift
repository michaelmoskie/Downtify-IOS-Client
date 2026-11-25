import SwiftUI

enum DowntifyAppearance: String, CaseIterable, Identifiable {
    case system, light, dark, oled

    static let storageKey = "downtify.appearance"
    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .oled: "OLED black"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .oled: .dark
        }
    }
}


/// A data-only theme. Imported themes can customize the shared surfaces and media components
/// without executing code or changing a server connection.
struct DowntifyTheme: Codable, Equatable {
    var version: Int
    var name: String
    var accentLight: String
    var accentDark: String
    var backgroundLight: String
    var backgroundDark: String
    var surfaceLight: String
    var surfaceDark: String
    var cardCornerRadius: Double
    var cardPadding: Double
    var rowSpacing: Double
    var albumGridMinimum: Double
    var homeSections: [String]
    var shelfLayout: String
    /// Optional so version 1 theme files created before these components remain valid.
    var navigationStyle: String? = nil
    var headerStyle: String? = nil
    var recentStyle: String? = nil
    var playerStyle: String? = nil
    var componentStyles: [String: String]? = nil
    var elevatedLight: String? = nil
    var elevatedDark: String? = nil
    var brandLight: String? = nil
    var brandDark: String? = nil
    var onBrandLight: String? = nil
    var onBrandDark: String? = nil
    var fontDesign: String? = nil
    var browseColors: [String: String]? = nil
    var surfaceStyle: String? = nil
    /// Optional equalizer colors. Each pair falls back to a shared palette color when omitted:
    /// accent (curve, fill and selected preset) to `accent`, handle to `brand`, grid (scale and labels)
    /// to the secondary text color.
    var equalizerAccentLight: String? = nil
    var equalizerAccentDark: String? = nil
    var equalizerHandleLight: String? = nil
    var equalizerHandleDark: String? = nil
    var equalizerGridLight: String? = nil
    var equalizerGridDark: String? = nil

    static let storageKey = "downtify.theme.json"
    /// Home sections every theme lists once, in its chosen order.
    static let requiredHomeSections = ["recent", "new", "favorites"]
    /// Home sections a theme may list once, or leave out to hide: the Discover card, the Your artists shelf,
    /// and the card for songs downloaded to this device.
    static let optionalHomeSections = ["discover", "artists", "downloaded"]
    /// Home without a theme.
    static let standardHomeSections = ["recent", "new", "discover", "favorites", "artists", "downloaded"]

    /// The Home sections to show, in order. Files written before the optional sections existed list none
    /// of them; they show all three after their own sections.
    var resolvedHomeSections: [String] {
        homeSections.contains(where: Self.optionalHomeSections.contains)
            ? homeSections : homeSections + Self.optionalHomeSections
    }
    static let example = DowntifyTheme(version: 1, name: "Redesign",
        accentLight: "14833B", accentDark: "1ED760", backgroundLight: "FFFFFF",
        backgroundDark: "121212", surfaceLight: "F3F3F3", surfaceDark: "1E1E1E",
        cardCornerRadius: 8, cardPadding: 16, rowSpacing: 12, albumGridMinimum: 142,
        homeSections: ["recent", "new", "discover", "favorites", "artists", "downloaded"], shelfLayout: "carousel",
        navigationStyle: "drawer", headerStyle: "profile", recentStyle: "tiles", playerStyle: "compact",
        componentStyles: ["home": "redesign", "library": "redesign", "search": "redesign",
                          "collection": "redesign", "downloads": "redesign", "player": "redesign",
                          "settings": "redesign", "connection": "redesign", "discover": "redesign",
                          "podcasts": "redesign", "queue": "redesign"],
        elevatedLight: "E8E8E8", elevatedDark: "2A2A2A", brandLight: "1DB954", brandDark: "1DB954",
        onBrandLight: "000000", onBrandDark: "000000", fontDesign: "system",
        browseColors: ["For You": "203562", "Charts": "E33600", "Finder": "27866F",
                       "Similar": "8863A8", "Podcasts": "006450", "Downloads": "B65B00"])

    func validate() throws {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80 else { throw ThemeError.invalid }
        for color in [accentLight, accentDark, backgroundLight, backgroundDark, surfaceLight, surfaceDark] {
            guard color.count == 6, color.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }) else { throw ThemeError.invalid }
        }
        for color in [elevatedLight, elevatedDark, brandLight, brandDark, onBrandLight, onBrandDark,
                      equalizerAccentLight, equalizerAccentDark, equalizerHandleLight, equalizerHandleDark,
                      equalizerGridLight, equalizerGridDark].compactMap({ $0 }) {
            guard color.count == 6, color.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }) else { throw ThemeError.invalid }
        }
        let browseNames = Set(["For You", "Charts", "Finder", "Similar", "Podcasts", "Downloads"])
        guard browseColors?.allSatisfy({ key, value in
            browseNames.contains(key) && value.count == 6 && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
        }) ?? true else { throw ThemeError.invalid }
        guard (elevatedLight == nil) == (elevatedDark == nil),
              (brandLight == nil) == (brandDark == nil),
              (onBrandLight == nil) == (onBrandDark == nil),
              (equalizerAccentLight == nil) == (equalizerAccentDark == nil),
              (equalizerHandleLight == nil) == (equalizerHandleDark == nil),
              (equalizerGridLight == nil) == (equalizerGridDark == nil) else { throw ThemeError.invalid }
        let componentNames = Set(["home", "library", "search", "collection", "downloads", "player", "settings", "connection", "discover", "podcasts", "queue"])
        guard componentStyles?.allSatisfy({ componentNames.contains($0.key) && ["standard", "redesign"].contains($0.value) }) ?? true,
              [nil, "system", "rounded", "serif", "monospaced"].contains(fontDesign) else { throw ThemeError.invalid }
        guard Set(Self.requiredHomeSections).isSubset(of: homeSections),
              Set(homeSections).isSubset(of: Self.requiredHomeSections + Self.optionalHomeSections),
              Set(homeSections).count == homeSections.count,
              ["grid", "list", "carousel"].contains(shelfLayout) else { throw ThemeError.invalid }
        guard [nil, "system", "custom"].contains(surfaceStyle),
              [nil, "system", "drawer"].contains(navigationStyle),
              [nil, "system", "profile"].contains(headerStyle),
              [nil, "shelf", "tiles"].contains(recentStyle),
              [nil, "standard", "compact"].contains(playerStyle) else { throw ThemeError.invalid }
        guard (0...40).contains(cardCornerRadius), (4...32).contains(cardPadding),
              (4...32).contains(rowSpacing), (100...240).contains(albumGridMinimum) else {
            throw ThemeError.invalid
        }
    }

    static func decode(_ data: Data) throws -> DowntifyTheme {
        guard data.count <= 16_384 else { throw ThemeError.invalid }
        let theme = try JSONDecoder().decode(Self.self, from: data)
        try theme.validate()
        return theme
    }

    static func bundled(_ name: String, bundle: Bundle = .main) throws -> DowntifyTheme {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "themes") else {
            throw ThemeError.invalid
        }
        return try decode(Data(contentsOf: url))
    }

    func color(light: String, dark: String) -> Color {
        DowntifyStyle.adaptive(light: UInt32(light, radix: 16) ?? 0, dark: UInt32(dark, radix: 16) ?? 0)
    }

    enum ThemeError: LocalizedError {
        case invalid
        var errorDescription: String? { "The theme contains unsupported or invalid values. See the theme format documentation." }
    }
}

/// Derives a subdued tint from actual artwork. Missing or unavailable artwork uses the theme surface.
/// Picks a background color from cover art that keeps white text readable.
enum ArtworkThemeTint {
    static func color(from image: UIImage) -> Color? {
        guard let cgImage = image.cgImage, cgImage.width >= 8, cgImage.height >= 8 else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Group colorful pixels into 12 hue buckets and take the heaviest bucket, so a busy cover yields
        // one of its real colors instead of a muddy average. Grey or black covers fall back to the average.
        var buckets = [(weight: Double, red: Double, green: Double, blue: Double)](repeating: (0, 0, 0, 0), count: 12)
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            red += r; green += g; blue += b; total += 1
            var h: CGFloat = 0, sat: CGFloat = 0, value: CGFloat = 0, a: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &sat, brightness: &value, alpha: &a)
            guard sat > 0.3, value > 0.2 else { continue }
            // Skin tones (orange hues at moderate saturation) are left out so portraits tint by their palette.
            if h < 0.11, sat < 0.62, value > 0.35 { continue }
            // Squared saturation favours vivid colours over skin tones and washed-out backgrounds.
            let weight = Double(sat * sat * value)
            let bucket = min(Int(h * 12), 11)
            buckets[bucket].weight += weight
            buckets[bucket].red += r * weight
            buckets[bucket].green += g * weight
            buckets[bucket].blue += b * weight
        }
        guard total > 0 else { return nil }
        let base: UIColor
        if let best = buckets.max(by: { $0.weight < $1.weight }), best.weight > 0.15 {
            base = UIColor(red: best.red / best.weight, green: best.green / best.weight, blue: best.blue / best.weight, alpha: 1)
        } else {
            base = UIColor(red: red / total, green: green / total, blue: blue / total, alpha: 1)
        }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return nil }
        let adjustedSaturation = saturation < 0.08 ? saturation : min(max(saturation, 0.35), 0.75)
        return Color(uiColor: UIColor(hue: hue, saturation: adjustedSaturation,
                                      brightness: min(max(brightness, 0.34), 0.52), alpha: 1))
    }
}

struct DowntifyPalette {
    var oled = false
    var theme: DowntifyTheme? = nil

    var accent: Color { theme.map { $0.color(light: $0.accentLight, dark: $0.accentDark) } ?? DowntifyStyle.accent }
    func redesign(_ component: String) -> Bool { theme?.componentStyles?[component] == "redesign" }
    var elevated: Color {
        guard let t = theme, let light = t.elevatedLight, let dark = t.elevatedDark else { return surface }
        return t.color(light: light, dark: dark)
    }
    var brand: Color {
        guard let t = theme, let light = t.brandLight, let dark = t.brandDark else { return accent }
        return t.color(light: light, dark: dark)
    }
    var onBrand: Color {
        guard let t = theme, let light = t.onBrandLight, let dark = t.onBrandDark else { return DowntifyStyle.onAccent }
        return t.color(light: light, dark: dark)
    }
    /// Equalizer curve, its fill, and the selected preset.
    var equalizerAccent: Color { pair(\.equalizerAccentLight, \.equalizerAccentDark) ?? accent }
    /// Equalizer band handles.
    var equalizerHandle: Color { pair(\.equalizerHandleLight, \.equalizerHandleDark) ?? brand }
    /// Equalizer dB scale, guide lines, and band labels; also the curve while the equalizer is off.
    var equalizerGrid: Color { pair(\.equalizerGridLight, \.equalizerGridDark) ?? DowntifyStyle.secondaryText }
    /// Corner radius and padding of themed cards outside `DowntifyCard`, with the given standard-theme defaults.
    func cardCornerRadius(default value: CGFloat) -> CGFloat { theme.map { CGFloat($0.cardCornerRadius) } ?? value }
    func cardPadding(default value: CGFloat) -> CGFloat { theme.map { CGFloat($0.cardPadding) } ?? value }

    private func pair(_ light: KeyPath<DowntifyTheme, String?>, _ dark: KeyPath<DowntifyTheme, String?>) -> Color? {
        guard let t = theme, let l = t[keyPath: light], let d = t[keyPath: dark] else { return nil }
        return t.color(light: l, dark: d)
    }
    var fontDesign: Font.Design {
        switch theme?.fontDesign {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
    }

    var background: Color {
        if oled { return .black }
        return theme.map { $0.color(light: $0.backgroundLight, dark: $0.backgroundDark) }
            ?? DowntifyStyle.adaptive(light: 0xF2F3F5, dark: 0x141618)
    }

    var surface: Color {
        if oled { return Color(uiColor: UIColor(white: 0.09, alpha: 1)) }
        if theme?.surfaceStyle == "system" { return Color(uiColor: .secondarySystemGroupedBackground) }
        return theme.map { $0.color(light: $0.surfaceLight, dark: $0.surfaceDark) }
            ?? Color(uiColor: .secondarySystemGroupedBackground)
    }
}

private struct DowntifyPaletteKey: EnvironmentKey {
    static let defaultValue = DowntifyPalette()
}

extension EnvironmentValues {
    var downtifyPalette: DowntifyPalette {
        get { self[DowntifyPaletteKey.self] }
        set { self[DowntifyPaletteKey.self] = newValue }
    }
}

extension View {
    func downtifyAppearance(_ appearance: DowntifyAppearance, theme: DowntifyTheme? = nil) -> some View {
        let palette = DowntifyPalette(oled: appearance == .oled, theme: theme)
        return environment(\.downtifyPalette, palette)
            .preferredColorScheme(appearance.colorScheme)
            .fontDesign(palette.fontDesign)
            .tint(palette.accent)
    }

    func downtifyControlTarget() -> some View {
        frame(minWidth: DowntifyStyle.minimumControlSize, minHeight: DowntifyStyle.minimumControlSize)
            .contentShape(Rectangle())
    }

    /// Leaves room to scroll the final action clear of the mini player, sized to the dock's measured height.
    /// The dock sits in a safe-area inset outside the tab's `NavigationStack`, which scroll views inside it
    /// do not reliably clear, so every vertically scrolling page in a tab applies this.
    func downtifyScrollEndClearance() -> some View {
        modifier(ScrollEndClearance())
    }
}

private struct ScrollEndClearance: ViewModifier {
    @Environment(\.playbackDockHeight) private var dockHeight

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, DowntifyStyle.scrollEndClearance(dockHeight: dockHeight), for: .scrollContent)
    }
}

private struct PlaybackDockHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Measured height of the playback dock below the current tab; 0 when nothing is playing.
    var playbackDockHeight: CGFloat {
        get { self[PlaybackDockHeightKey.self] }
        set { self[PlaybackDockHeightKey.self] = newValue }
    }
}

/// Shared semantic colors, spacing, and surfaces used throughout the app.
enum DowntifyStyle {
    static let accent = adaptive(light: 0x17623E, dark: 0x72D9A0)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x09160F)
    static let error = adaptive(light: 0xAE252E, dark: 0xFF9B9E)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let minimumControlSize: CGFloat = 44

    /// Bottom content margin that keeps the final row clear of a dock of the given height. Never less than
    /// `Space.scrollEnd`; grows for taller docks such as the stacked accessibility-size layout.
    static func scrollEndClearance(dockHeight: CGFloat) -> CGFloat {
        max(Space.scrollEnd, dockHeight + Space.regular)
    }

    enum Space {
        static let small: CGFloat = 8
        static let regular: CGFloat = 16
        static let large: CGFloat = 24
        static let section: CGFloat = 36
        static let scrollEnd: CGFloat = 96
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

struct DowntifyCard<Content: View>: View {
    @Environment(\.downtifyPalette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(palette.theme.map { CGFloat($0.cardPadding) } ?? DowntifyStyle.Space.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: palette.theme.map { CGFloat($0.cardCornerRadius) } ?? 20))
    }
}

/// Artwork, metadata, and optional trailing information shared by media lists.
struct DowntifyMediaRow<Artwork: View, Accessory: View>: View {
    @Environment(\.downtifyPalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String
    var detail: String? = nil
    var accessibilityLineLimit: Int? = nil
    /// Marks the queue's current song: accent title plus the now-playing badge.
    var isCurrent = false
    var isPlaying = false
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: palette.theme.map { CGFloat($0.rowSpacing) } ?? 12) {
            artwork.accessibilityHidden(true)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    metadata
                    accessory
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                metadata
                    .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
        }
        .frame(minHeight: DowntifyStyle.minimumControlSize)
        .contentShape(Rectangle())
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isCurrent { NowPlayingBadge(isPlaying: isPlaying) }
                Text(title).font(.body.weight(.semibold))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.primary))
            }
            Text(subtitle).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
            }
        }
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? accessibilityLineLimit : 1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reads now-playing state inside one row, so a song change re-renders rows rather than whole lists.
struct NowPlayingReader<Content: View>: View {
    @EnvironmentObject private var nowPlaying: NowPlayingIndicator
    @ViewBuilder let content: (NowPlayingIndicator) -> Content

    var body: some View { content(nowPlaying) }
}

/// Speaker glyph shown beside the current song. Animates only while audio is playing and motion is allowed.
struct NowPlayingBadge: View {
    @Environment(\.downtifyPalette) private var palette
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.accent)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying && !reduceMotion)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Announces the current song as selected with a "Now playing" or "Paused" value.
    /// Pass any value the row already announces (such as its duration) as `value` so both are kept.
    func downtifyCurrentRowAccessibility(isCurrent: Bool, isPlaying: Bool, value: String? = nil) -> some View {
        let state = isCurrent ? (isPlaying ? String(localized: "Now playing") : String(localized: "Paused")) : nil
        let combined = [state, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return accessibilityAddTraits(isCurrent ? .isSelected : [])
            .accessibilityValue(Text(verbatim: combined))
    }
}

struct DowntifyUnavailableView: View {
    let title: LocalizedStringKey
    let symbol: String
    var message: Text? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            message
        } actions: {
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
            }
        }
    }
}
