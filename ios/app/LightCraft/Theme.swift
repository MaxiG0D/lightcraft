import SwiftUI

/// The desktop's Appearance Mode (Settings ▸ Interface): follow the system, or force the light or
/// dark family. Each family has its own theme (Charcoal / Midnight, Silver / Paper), as on desktop.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var icon: LCIcon {
        switch self {
        case .auto: .monitor
        case .light: .sun
        case .dark: .moon
        }
    }
}

/// Appearance choices, remembered between launches.
@MainActor
@Observable
final class Appearance {
    var mode: AppearanceMode { didSet { save() } }
    var darkTheme: String { didSet { save() } }
    var lightTheme: String { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        mode = AppearanceMode(rawValue: d.string(forKey: "appearance.mode") ?? "") ?? .auto
        darkTheme = d.string(forKey: "appearance.dark") ?? LCTokens.charcoal.id
        lightTheme = d.string(forKey: "appearance.light") ?? LCTokens.silver.id
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: "appearance.mode")
        d.set(darkTheme, forKey: "appearance.dark")
        d.set(lightTheme, forKey: "appearance.light")
    }

    /// The colour scheme to force, or nil to follow the system.
    var preferredScheme: ColorScheme? {
        switch mode {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func tokens(for scheme: ColorScheme) -> LCTokens {
        let id = scheme == .dark ? darkTheme : lightTheme
        let fallback: LCTokens = scheme == .dark ? .charcoal : .silver
        return LCTokens.all.first { $0.id == id && $0.isDark == (scheme == .dark) } ?? fallback
    }
}

private struct TokensKey: EnvironmentKey {
    static let defaultValue = LCTokens.charcoal
}

extension EnvironmentValues {
    /// The current desktop theme.
    var lc: LCTokens {
        get { self[TokensKey.self] }
        set { self[TokensKey.self] = newValue }
    }
}

/// The desktop UI font (Inter, bundled from assets/fonts). Sizes are the desktop's points.
enum LCFont {
    static func regular(_ size: CGFloat) -> Font { .custom("Inter-Regular", fixedSize: size) }
    static func medium(_ size: CGFloat) -> Font { .custom("Inter-Medium", fixedSize: size) }
    static func semibold(_ size: CGFloat) -> Font { .custom("Inter-SemiBold", fixedSize: size) }
}

extension Image {
    /// A desktop icon (template image, tinted with the foreground style).
    init(lc icon: LCIcon) {
        self.init(icon.rawValue)
    }
}

/// A desktop icon at the desktop's size, in its icon colour.
struct LCIconView: View {
    @Environment(\.lc) private var t
    let icon: LCIcon
    var size: CGFloat = 20
    var color: Color?

    var body: some View {
        Image(lc: icon)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .foregroundStyle(color ?? t.icon)
    }
}
