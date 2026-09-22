import CoreGraphics
import Foundation

public struct ContextTextFilter {
    public var maxLines: Int
    public var verticalLookback: CGFloat
    public var horizontalPadding: CGFloat

    public init(maxLines: Int = 12, verticalLookback: CGFloat = 900, horizontalPadding: CGFloat = 260) {
        self.maxLines = maxLines
        self.verticalLookback = verticalLookback
        self.horizontalPadding = horizontalPadding
    }

    public func tuned(for appInfo: AppInfo) -> ContextTextFilter {
        let bundle = appInfo.bundleIdentifier?.lowercased() ?? ""
        let name = appInfo.name.lowercased()

        if bundle.contains("slack") || name.contains("slack") {
            return ContextTextFilter(maxLines: 14, verticalLookback: 1_100, horizontalPadding: 420)
        }

        if isBrowser(bundle: bundle, name: name) {
            return ContextTextFilter(maxLines: 22, verticalLookback: 1_650, horizontalPadding: 620)
        }

        if bundle.contains("mail") || bundle.contains("outlook") || name.contains("gmail") {
            return ContextTextFilter(maxLines: 18, verticalLookback: 1_450, horizontalPadding: 520)
        }

        if bundle.contains("discord") || bundle.contains("teams") || bundle.contains("line") {
            return ContextTextFilter(maxLines: 14, verticalLookback: 1_000, horizontalPadding: 420)
        }

        return self
    }

    private func isBrowser(bundle: String, name: String) -> Bool {
        let browserSignals = [
            "chrome",
            "safari",
            "arc",
            "edgemac",
            "microsoft.edge",
            "firefox",
            "thebrowser"
        ]

        return browserSignals.contains { signal in
            bundle.contains(signal) || name.contains(signal)
        }
    }

    public func filter(
        lines: [ContextLine],
        inputFrame: CGRect?,
        draft: String
    ) -> [ContextLine] {
        let draftClean = normalize(draft)
        var seen = Set<String>()

        let cleaned = lines.compactMap { line -> ContextLine? in
            let text = normalize(line.text)
            guard shouldKeep(text: text, draft: draftClean) else {
                return nil
            }
            guard seen.insert(text.lowercased()).inserted else {
                return nil
            }
            return ContextLine(text: text, frame: line.frame)
        }

        let spatiallyFiltered: [ContextLine]
        if let inputFrame {
            spatiallyFiltered = cleaned.filter { line in
                guard let frame = line.frame else {
                    return true
                }
                return isNearAndAboveInput(frame: frame, inputFrame: inputFrame)
            }
        } else {
            spatiallyFiltered = cleaned
        }

        let inReadingOrder = spatiallyFiltered.sorted { lhs, rhs in
            guard let left = lhs.frame, let right = rhs.frame else {
                return lhs.text < rhs.text
            }
            if abs(left.minY - right.minY) > 2 {
                return left.minY < right.minY
            }
            return left.minX < right.minX
        }

        // Cap by keeping the thread opening and the latest lines, not only the nearest ones.
        return ContextWindow.headAndTail(inReadingOrder, limit: maxLines)
    }

    private func shouldKeep(text: String, draft: String) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        guard text.count >= 2, text.count <= 600 else {
            return false
        }
        guard !isDraftEcho(text: text, draft: draft) else {
            return false
        }

        let noise = Set([
            "send", "sent", "reply", "message", "search", "today", "yesterday",
            "threads", "mentions", "drafts", "apps", "canvases", "files", "later",
            "jump to", "add reaction", "more actions", "new message",
            "home", "watch", "marketplace", "groups", "gaming", "notifications",
            "messenger", "facebook", "meta", "like", "comment", "share",
            "送信", "返信", "検索", "今日", "昨日", "スレッド", "メンション", "下書き",
            "ファイル", "アプリ", "未読", "新規メッセージ",
            "ホーム", "通知", "メッセンジャー", "いいね", "コメント", "シェア"
        ])
        let lowercased = text.lowercased()
        guard !noise.contains(lowercased) else {
            return false
        }

        let noisyPrefixes = [
            "message #", "message @", "search ", "jump to ", "add reaction",
            "type a message", "write a message", "write a reply",
            "返信先:", "宛先:", "検索 ", "https://", "http://", "www."
        ]

        guard !noisyPrefixes.contains(where: { lowercased.hasPrefix($0) }) else {
            return false
        }

        return !looksLikeUIOnlyText(text)
    }

    private func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isNearAndAboveInput(frame: CGRect, inputFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 12
        let horizontallyRelated = horizontalOverlap(frame, inputFrame) > 0
            || abs(frame.midX - inputFrame.midX) <= max(inputFrame.width, 320)
            || frame.intersects(inputFrame.insetBy(dx: -horizontalPadding, dy: -verticalLookback))

        guard horizontallyRelated else {
            return false
        }

        // Accessibility coordinates are usually top-left based, but this also
        // tolerates bottom-left based values from unusual apps.
        let topOriginAbove = frame.maxY <= inputFrame.minY + tolerance
            && inputFrame.minY - frame.maxY <= verticalLookback
        let bottomOriginAbove = frame.minY >= inputFrame.maxY - tolerance
            && frame.minY - inputFrame.maxY <= verticalLookback

        return topOriginAbove || bottomOriginAbove
    }

    private func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX + horizontalPadding) - max(lhs.minX, rhs.minX - horizontalPadding))
    }

    private func isDraftEcho(text: String, draft: String) -> Bool {
        guard !draft.isEmpty else {
            return false
        }

        if text == draft {
            return true
        }

        return text.contains(draft) && text.count <= draft.count + 24
    }

    private func looksLikeUIOnlyText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        if trimmed.count <= 2 {
            return true
        }

        let symbolCount = trimmed.unicodeScalars.filter {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }.count

        return symbolCount >= max(3, trimmed.count / 2)
    }
}
