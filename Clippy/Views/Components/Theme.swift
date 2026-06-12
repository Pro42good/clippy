import SwiftUI

enum ClippyTheme {
    static let background = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let surface = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let surfaceElevated = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let accent = Color(red: 0.18, green: 0.85, blue: 0.42)
    static let accentDim = Color(red: 0.12, green: 0.55, blue: 0.28)
    static let accentGlow = Color(red: 0.18, green: 0.85, blue: 0.42).opacity(0.35)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let border = Color.white.opacity(0.08)

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.78)
    static let springBouncy = Animation.spring(response: 0.55, dampingFraction: 0.62)
    static let easeOut = Animation.easeOut(duration: 0.35)
}

struct ClippyCardStyle: ViewModifier {
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ClippyTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isHighlighted ? ClippyTheme.accent.opacity(0.6) : ClippyTheme.border, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func clippyCard(highlighted: Bool = false) -> some View {
        modifier(ClippyCardStyle(isHighlighted: highlighted))
    }

    func clippyGlow(isActive: Bool) -> some View {
        shadow(color: isActive ? ClippyTheme.accentGlow : .clear, radius: isActive ? 18 : 0)
    }
}
