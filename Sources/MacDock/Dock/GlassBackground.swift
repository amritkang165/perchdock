import SwiftUI

/// Liquid Glass on macOS 26+, frosted material before that.
struct GlassBackground: ViewModifier {
    let fltCornerRadius: CGFloat

    /// Applies the background appropriate for the running OS.
    /// - Parameter content: The view being decorated.
    /// - Returns: The decorated view.
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: fltCornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: .rect(cornerRadius: fltCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: fltCornerRadius)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        }
    }
}

extension View {
    /// Applies MacDock's glass background.
    /// - Parameter fltCornerRadius: Corner radius of the glass shape.
    /// - Returns: The decorated view.
    func dockGlass(cornerRadius fltCornerRadius: CGFloat) -> some View {
        modifier(GlassBackground(fltCornerRadius: fltCornerRadius))
    }
}
