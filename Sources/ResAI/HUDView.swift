import SwiftUI

struct HUDView: View {
    var message: HUDMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(message.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    if let detail = message.detail {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let preview = message.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch message.tone {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.red)
        case .idle:
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
        }
    }

    private var borderColor: Color {
        switch message.tone {
        case .loading:
            .blue
        case .success:
            .green
        case .warning:
            .orange
        case .error:
            .red
        case .idle:
            .secondary
        }
    }
}
