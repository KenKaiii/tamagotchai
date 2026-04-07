import SwiftUI

/// A translucent, glassmorphism-style button for use in HUD panels.
struct GlassButton: View {
    let title: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, isPrimary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isPrimary = isPrimary
        self.action = action
    }

    var body: some View {
        Button {
            ButtonSound.shared.play()
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isPrimary ? .semibold : .medium))
                .foregroundColor(.white.opacity(isPrimary ? 1.0 : 0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isPrimary
                            ? Color.white.opacity(isHovering ? 0.2 : 0.14)
                            : Color.white.opacity(isHovering ? 0.14 : 0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(isPrimary ? 0.25 : 0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
