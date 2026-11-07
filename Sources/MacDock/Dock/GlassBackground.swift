import SwiftUI
import AppKit

/// Liquid Glass on macOS 26+, frosted material before that, with an optional
/// color wash.
struct GlassBackground: ViewModifier {
    let fltCornerRadius: CGFloat
    /// Color wash already including its strength (alpha), or `nil` for clear glass.
    let objTint: Color?

    /// Applies the background appropriate for the running OS.
    /// - Parameter content: The view being decorated.
    /// - Returns: The decorated view.
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // The tint is a color layer between the glass and the content (the glass's
            // own tint is too faint to notice; an overlay would tint the icons too).
            content
                .background(RoundedRectangle(cornerRadius: fltCornerRadius).fill(objTint ?? .clear).allowsHitTesting(false))
                .glassEffect(.regular, in: .rect(cornerRadius: fltCornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: fltCornerRadius))
                .background((objTint ?? .clear), in: .rect(cornerRadius: fltCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: fltCornerRadius)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
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
