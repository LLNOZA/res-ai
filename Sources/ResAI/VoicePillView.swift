import SwiftUI

enum VoicePillState: Equatable {
    case listening(level: Float, text: String)
    case finishing(text: String)
    case inserted(text: String)
    case cleaning(text: String)
    case cleaned(text: String)
    case error(message: String)

    var autoHideDuration: TimeInterval? {
        switch self {
        case .listening, .finishing, .cleaning:
            nil
        case .inserted:
            1.2
        case .cleaned:
            1.6
        case .error:
            2.5
        }
    }

    var displayText: String {
        switch self {
        case .listening(_, let text), .finishing(let text), .inserted(let text), .cleaning(let text), .cleaned(let text):
            text
        case .error(let message):
            message
        }
    }

    var layoutKind: VoicePillLayoutKind {
        switch self {
        case .listening: .listening
        case .finishing: .finishing
        case .inserted: .inserted
        case .cleaning: .cleaning
        case .cleaned: .cleaned
        case .error: .error
        }
    }
}

enum VoicePillLayoutKind: Equatable {
    case listening, finishing, inserted, cleaning, cleaned, error
}

@MainActor
final class VoicePillModel: ObservableObject {
    @Published var state: VoicePillState = .listening(level: 0, text: "")
    @Published var hint: String?
    @Published var isVisible = false
    @Published var level: Float = 0
}

struct VoicePillView: View {
    static let height: CGFloat = 40
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 520
    static let shadowPadding: CGFloat = 16

    @ObservedObject var model: VoicePillModel

    var body: some View {
        HStack(spacing: 10) {
            leadingAccessory
                .frame(width: 27, height: 22)

            transcriptLabel

            if showsHint, let hint = model.hint, !hint.isEmpty {
                hintLabel(hint)
            } else if case .finishing = model.state {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: Self.minWidth, maxWidth: Self.maxWidth, alignment: .leading)
        .frame(height: Self.height)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .padding(Self.shadowPadding)
        .scaleEffect(model.isVisible ? 1 : 0.96)
        .opacity(model.isVisible ? 1 : 0)
        .animation(model.isVisible ? .easeOut(duration: 0.12) : .easeOut(duration: 0.16), value: model.isVisible)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        switch model.state {
        case .listening:
            WaveformBars(level: model.level, tint: Color.primary.opacity(0.85))
        case .finishing:
            WaveformBars(level: model.level, tint: .blue)
        case .inserted, .cleaned:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)
        case .cleaning:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.blue)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var transcriptLabel: some View {
        let text = model.state.displayText
        let isPlaceholder = isListeningPlaceholder
        Text(isPlaceholder ? "話してください" : text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintLabel(_ hint: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "keyboard")
                .font(.system(size: 16))
            Text(hint)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var showsHint: Bool {
        guard case .listening = model.state else {
            return false
        }
        return model.hint?.isEmpty == false
    }

    private var isListeningPlaceholder: Bool {
        if case .listening(_, let text) = model.state {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
}

private struct WaveformBars: View {
    var level: Float
    var tint: Color

    private let weights: [CGFloat] = [0.42, 0.78, 1.0, 0.72, 0.48]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: barHeight(index))
                    .animation(.spring(response: 0.18, dampingFraction: 0.7), value: level)
            }
        }
        .frame(height: 22, alignment: .center)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return 6 + 16 * clamped * weights[index]
    }
}
