import SwiftUI

struct FloatingButtonView: View {
    var onRewrite: () -> Void
    var onRestore: () -> Void
    var onSettings: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    var body: some View {
        Button(action: onRewrite) {
            ZStack {
                glassBackground

                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .shadow(color: .white.opacity(0.32), radius: 1.2, x: 0, y: 1)
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .scaleEffect(isHovering ? 1.045 : 1.0)
            .animation(.snappy(duration: 0.18), value: isHovering)
        }
        .buttonStyle(FloatingGlassButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
        .help("下書きを整える")
        .accessibilityLabel("ResponseAiで下書きを整える")
        .contextMenu {
            Button(action: onRewrite) {
                Label("返信を整える", systemImage: "sparkles")
            }
            Button(action: onRestore) {
                Label("直前の下書きに戻す", systemImage: "arrow.uturn.backward")
            }
            Divider()
            Button(action: onSettings) {
                Label("設定", systemImage: "gearshape")
            }
        }
    }

    private var glassBackground: some View {
        ZStack {
            if reduceTransparency {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
            } else {
                Circle()
                    .fill(.thinMaterial)
            }
        }
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(isHovering ? 0.34 : 0.24),
                                .white.opacity(0.04),
                                .black.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.accentColor.opacity(isHovering ? 0.12 : 0.06),
                                .clear
                            ],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 44
                        )
                    )
            )
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(isHovering ? 0.54 : 0.36), lineWidth: 0.8)
            )
            .overlay(
                Circle()
                    .inset(by: 0.8)
                    .strokeBorder(.black.opacity(0.12), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(isHovering ? 0.24 : 0.18), radius: isHovering ? 16 : 11, x: 0, y: isHovering ? 8 : 5)
            .shadow(color: .white.opacity(0.18), radius: 2, x: -1, y: -1)
    }
}

private struct FloatingGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}
