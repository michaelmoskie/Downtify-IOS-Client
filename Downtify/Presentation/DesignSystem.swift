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

struct DowntifyPalette {
    var oled = false

    var background: Color {
        oled ? .black : DowntifyStyle.adaptive(light: 0xF2F3F5, dark: 0x141618)
    }

    var surface: Color {
        oled ? Color(uiColor: UIColor(white: 0.09, alpha: 1)) : Color(uiColor: .secondarySystemGroupedBackground)
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
    func downtifyAppearance(_ appearance: DowntifyAppearance) -> some View {
        environment(\.downtifyPalette, DowntifyPalette(oled: appearance == .oled))
            .preferredColorScheme(appearance.colorScheme)
            .tint(DowntifyStyle.accent)
    }

    func downtifyControlTarget() -> some View {
        frame(minWidth: DowntifyStyle.minimumControlSize, minHeight: DowntifyStyle.minimumControlSize)
            .contentShape(Rectangle())
    }

    /// Leaves room to scroll the final action clear of the mini player.
    func downtifyScrollEndClearance() -> some View {
        contentMargins(.bottom, DowntifyStyle.Space.scrollEnd, for: .scrollContent)
    }
}

/// Shared semantic colors, spacing, and surfaces used throughout the app.
enum DowntifyStyle {
    static let accent = adaptive(light: 0x17623E, dark: 0x72D9A0)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x09160F)
    static let error = adaptive(light: 0xAE252E, dark: 0xFF9B9E)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let minimumControlSize: CGFloat = 44

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
            .padding(DowntifyStyle.Space.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Artwork, metadata, and optional trailing information shared by media lists.
struct DowntifyMediaRow<Artwork: View, Accessory: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String
    var detail: String? = nil
    var accessibilityLineLimit: Int? = nil
    @ViewBuilder var artwork: Artwork
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
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
            Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
            Text(subtitle).font(.subheadline).foregroundStyle(DowntifyStyle.secondaryText)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(DowntifyStyle.secondaryText)
            }
        }
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? accessibilityLineLimit : 1)
        .fixedSize(horizontal: false, vertical: true)
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
