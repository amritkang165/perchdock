import SwiftUI
import AppKit

/// How MacDock's surfaces (dock, previews, folder grids, labels) are rendered.
enum GlassStyle: String, CaseIterable, Identifiable {
    /// Liquid Glass: refracts and blurs what's behind (frosted material before macOS 26).
    case liquid
    /// Highly transparent Liquid Glass with only a light blur.
    case clear
    /// Classic frosted blur without Liquid Glass refraction.
    case frosted

    var id: String { rawValue }

    /// Display name.
    var strTitle: String {
        switch self {
        case .liquid: "Liquid Glass"
        case .clear: "Clear Glass"
        case .frosted: "Frosted"
        }
    }
}

/// Glass settings every surface reads, mirrored from `SettingsStore` so views that
/// don't hold the store still update live.
@MainActor
@Observable
final class GlassAppearance {
    static let shared = GlassAppearance()

    /// Rendering style.
    var enmStyle: GlassStyle = .liquid
    /// 1 = only the glass; lower values lay an increasingly opaque backing over it (0 = solid).
    var fltTransparency: Double = 1

    private init() {}
}

/// Glass background in the user's chosen style and transparency, with an optional
/// color wash.
struct GlassBackground: ViewModifier {
    let fltCornerRadius: CGFloat
    /// Color wash already including its strength (alpha), or `nil` for clear glass.
    let objTint: Color?

    /// Applies the background appropriate for the running OS and settings.
    /// - Parameter content: The view being decorated.
    /// - Returns: The decorated view.
    func body(content: Content) -> some View {
        let objAppearance = GlassAppearance.shared
        let objShape = RoundedRectangle(cornerRadius: fltCornerRadius, style: .continuous)

        // Backing and tint sit between the glass and the content (an overlay would
        // tint the icons too). Less transparency = a more opaque window-colored backing.
        let objLayers = content
            .background(objShape.fill(objTint ?? .clear).allowsHitTesting(false))
            .background(objShape.fill(Color(nsColor: .windowBackgroundColor)
                .opacity(0.94 * (1 - objAppearance.fltTransparency))).allowsHitTesting(false))

        if #available(macOS 26.0, *), objAppearance.enmStyle != .frosted {
            objLayers
                .glassEffect(objAppearance.enmStyle == .clear ? .clear : .regular,
                             in: .rect(cornerRadius: fltCornerRadius))
        } else {
            objLayers
                .background(objAppearance.enmStyle == .clear ? .ultraThinMaterial : .regularMaterial, in: objShape)
                .overlay(objShape.strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Applies MacDock's glass background.
    /// - Parameters:
    ///   - fltCornerRadius: Corner radius of the glass shape.
    ///   - objTint: Optional color wash.
    /// - Returns: The decorated view.
    func dockGlass(cornerRadius fltCornerRadius: CGFloat, tint objTint: Color? = nil) -> some View {
        modifier(GlassBackground(fltCornerRadius: fltCornerRadius, objTint: objTint))
    }
}

extension Color {
    /// Parses `#RRGGBB` (the `#` is optional); falls back to blue.
    /// - Parameter strHex: Hex string.
    init(strHex: String) {
        let strClean = strHex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let intValue = UInt32(strClean, radix: 16) ?? 0x3B82F6
        self.init(
            red: Double((intValue >> 16) & 0xFF) / 255,
            green: Double((intValue >> 8) & 0xFF) / 255,
            blue: Double(intValue & 0xFF) / 255
        )
    }

    /// The color as `#RRGGBB` (sRGB).
    var strHex: String {
        let objColor = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X",
                      Int((objColor.redComponent * 255).rounded()),
                      Int((objColor.greenComponent * 255).rounded()),
                      Int((objColor.blueComponent * 255).rounded()))
    }
}

extension SettingsStore {
    /// Tint for the dock's glass from appearance settings, or `nil` for none.
    @MainActor
    var objDockTint: Color? {
        switch enmTint {
        case .none: nil
        case .accent: Color.accentColor.opacity(fltTintStrength)
        case .custom: Color(strHex: strTintHex).opacity(fltTintStrength)
        }
    }
}
