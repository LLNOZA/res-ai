import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum FormFieldValueState: String, Codable, Equatable, Sendable {
    case known
    case unknown
}

public struct FormFieldSnapshot: Codable, Equatable {
    public var index: Int
    public var label: String
    public var placeholder: String
    public var currentValue: String
    public var role: String
    /// `.unknown` means AXValue could not be read. Unknown is never treated as an empty field.
    public var valueState: FormFieldValueState

    public init(
        index: Int,
        label: String,
        placeholder: String = "",
        currentValue: String = "",
        role: String = "",
        valueState: FormFieldValueState = .known
    ) {
        self.index = index
        self.label = label
        self.placeholder = placeholder
        self.currentValue = currentValue
        self.role = role
        self.valueState = valueState
    }

    public var isEmpty: Bool {
        valueState == .known && currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case index, label, placeholder, currentValue, role, valueState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        label = try container.decode(String.self, forKey: .label)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        currentValue = try container.decodeIfPresent(String.self, forKey: .currentValue) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        valueState = try container.decodeIfPresent(FormFieldValueState.self, forKey: .valueState) ?? .known
    }
}

public struct CapturedFormField: @unchecked Sendable {
    public var element: AXUIElement
    public var frame: CGRect?
    public var snapshot: FormFieldSnapshot

    public init(element: AXUIElement, frame: CGRect?, snapshot: FormFieldSnapshot) {
        self.element = element
        self.frame = frame
        self.snapshot = snapshot
    }
}

public struct CapturedForm: @unchecked Sendable {
    public var appInfo: AppInfo
    public var fields: [CapturedFormField]

    public init(appInfo: AppInfo, fields: [CapturedFormField]) {
        self.appInfo = appInfo
        self.fields = fields
    }

    public var snapshots: [FormFieldSnapshot] {
        fields.map(\.snapshot)
    }
}

public struct FormFillRequest: Equatable {
    public var appInfo: AppInfo
    public var fields: [FormFieldSnapshot]
    public var userProfile: UserProfile

    public init(appInfo: AppInfo, fields: [FormFieldSnapshot], userProfile: UserProfile) {
        self.appInfo = appInfo
        self.fields = fields
        self.userProfile = userProfile
    }
}

public struct FormFillSuggestion: Codable, Equatable {
    public var fieldIndex: Int
    public var value: String
    public var confidence: Double
    public var reason: String

    public init(fieldIndex: Int, value: String, confidence: Double, reason: String = "") {
        self.fieldIndex = fieldIndex
        self.value = value
        self.confidence = confidence
        self.reason = reason
    }
}

public enum FormFillError: LocalizedError {
    case focusedElementUnavailable

    public var errorDescription: String? {
        switch self {
        case .focusedElementUnavailable:
            "Focused form could not be read through Accessibility."
        }
    }
}

public final class FormReader: @unchecked Sendable {
    private let maxTraversalDepth: Int
    private let maxCollectedFields: Int
    private let maxVisitedNodes: Int
    private let maxScanMilliseconds: UInt64

    public init(
        maxTraversalDepth: Int = 10,
        maxCollectedFields: Int = 40,
        maxVisitedNodes: Int = 500,
        maxScanMilliseconds: UInt64 = 750
    ) {
        self.maxTraversalDepth = maxTraversalDepth
        self.maxCollectedFields = maxCollectedFields
        self.maxVisitedNodes = max(1, maxVisitedNodes)
        self.maxScanMilliseconds = max(1, maxScanMilliseconds)
    }

    /// Synchronous compatibility entry point. New callers should use the async method so AX
    /// traversal never blocks the main actor.
    public func captureFocusedFormSync() throws -> CapturedForm {
        try captureFocusedFormSynchronously()
    }

    /// Captures a bounded form snapshot off the caller's actor. The traversal stops at both a
    /// node budget and a wall-clock budget and returns the partial result collected so far.
    public func captureFocusedForm() async throws -> CapturedForm {
        let reader = self
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try reader.captureFocusedFormSynchronously()
        }.value
    }

    private func captureFocusedFormSynchronously() throws -> CapturedForm {
        let systemWide = AXHelpers.systemWide()
        guard
            let focusedValue = AXHelpers.copyAttribute(
                kAXFocusedUIElementAttribute as CFString,
                from: systemWide
            )
        else {
            throw FormFillError.focusedElementUnavailable
        }

        guard let focusedElement = AXHelpers.uiElement(from: focusedValue) else {
            throw FormFillError.focusedElementUnavailable
        }
        AXHelpers.applyMessagingTimeout(focusedElement)
        var pid: pid_t = 0
        AXUIElementGetPid(focusedElement, &pid)
        let appInfo = appInfo(for: pid)
        let appElement = AXHelpers.application(pid: pid)
        let focusedWindow = AXHelpers.copyUIElement(
            kAXFocusedWindowAttribute as CFString,
            from: appElement
        )
        let root = focusedWindow ?? appElement
        let scanned = scan(root: root)
        let fields = scanned.fields.enumerated().map { index, field in
            let label = label(for: field, textLines: scanned.textLines, fallbackIndex: index)
            let snapshot = FormFieldSnapshot(
                index: index,
                label: label,
                placeholder: field.placeholder,
                currentValue: field.currentValue ?? "",
                role: field.role,
                valueState: field.currentValue == nil ? .unknown : .known
            )
            return CapturedFormField(element: field.element, frame: field.frame, snapshot: snapshot)
        }

        return CapturedForm(appInfo: appInfo, fields: fields)
    }

    /// Re-reads a field immediately before mutation. Unknown, stale, or changed values are
    /// rejected; only a field that was known empty at capture time and is still empty is safe.
    public func revalidateEmpty(_ field: CapturedFormField) -> Bool {
        guard field.snapshot.valueState == .known, field.snapshot.isEmpty else {
            return false
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(field.element, &pid) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return false
        }
        let appElement = AXHelpers.application(pid: pid)
        guard
            let fieldWindow = AXHelpers.copyUIElement(kAXWindowAttribute as CFString, from: field.element),
            let focusedWindow = AXHelpers.copyUIElement(kAXFocusedWindowAttribute as CFString, from: appElement),
            CFEqual(fieldWindow, focusedWindow)
        else {
            // A missing window relationship is ambiguous (for example, a stale browser AX node),
            // so fail closed rather than trusting a merely empty value.
            return false
        }
        guard let current = AXHelpers.copyString(kAXValueAttribute as CFString, from: field.element) else {
            return false
        }
        return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func appInfo(for pid: pid_t) -> AppInfo {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return AppInfo(name: "Unknown App", bundleIdentifier: nil, processIdentifier: pid)
        }

        return AppInfo(
            name: app.localizedName ?? "Unknown App",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: pid
        )
    }

    private func scan(root: AXUIElement) -> FormScanResult {
        var fields: [RawFormField] = []
        var textLines: [ContextLine] = []
        var visited = Set<UInt>()
        let deadline = DispatchTime.now().uptimeNanoseconds + maxScanMilliseconds * 1_000_000

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maxTraversalDepth else {
                return
            }
            guard fields.count < maxCollectedFields else {
                return
            }
            guard visited.count < maxVisitedNodes else {
                return
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return
            }
            if Task.isCancelled {
                return
            }

            let identity = CFHash(element)
            guard visited.insert(identity).inserted else {
                return
            }

            let role = AXHelpers.copyString(kAXRoleAttribute as CFString, from: element) ?? ""
            if isFillableTextRole(role, element: element) {
                let currentValue = AXHelpers.copyString(kAXValueAttribute as CFString, from: element)
                fields.append(RawFormField(
                    element: element,
                    role: role,
                    frame: AXHelpers.frame(of: element),
                    currentValue: currentValue.map(normalized),
                    placeholder: normalized(AXHelpers.copyString("AXPlaceholderValue" as CFString, from: element) ?? ""),
                    ownLabel: ownLabel(from: element)
                ))
            } else if let text = textLine(from: element, role: role) {
                textLines.append(text)
            }

            for child in AXHelpers.copyChildren(from: element) {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return FormScanResult(fields: fields, textLines: textLines)
    }

    private func isFillableTextRole(_ role: String, element: AXUIElement) -> Bool {
        let subrole = AXHelpers.copyString(kAXSubroleAttribute as CFString, from: element)?.lowercased() ?? ""
        let roleLower = role.lowercased()
        guard !roleLower.contains("secure"), !subrole.contains("secure") else {
            return false
        }

        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
    }

    private func ownLabel(from element: AXUIElement) -> String {
        [
            AXHelpers.copyString(kAXTitleAttribute as CFString, from: element),
            AXHelpers.copyString(kAXDescriptionAttribute as CFString, from: element),
            AXHelpers.copyString("AXPlaceholderValue" as CFString, from: element),
            AXHelpers.copyString(kAXHelpAttribute as CFString, from: element)
        ]
        .compactMap { $0 }
        .map(normalized)
        .filter { !$0.isEmpty }
        .uniqued()
        .joined(separator: " ")
    }

    private func textLine(from element: AXUIElement, role: String) -> ContextLine? {
        guard role == kAXStaticTextRole as String || role == kAXGroupRole as String else {
            return nil
        }

        let rawText = AXHelpers.copyString(kAXValueAttribute as CFString, from: element)
            ?? AXHelpers.copyString(kAXTitleAttribute as CFString, from: element)
            ?? AXHelpers.copyString(kAXDescriptionAttribute as CFString, from: element)
        let text = normalized(rawText ?? "")
        guard text.count >= 2, text.count <= 160 else {
            return nil
        }
        return ContextLine(text: text, frame: AXHelpers.frame(of: element))
    }

    private func label(for field: RawFormField, textLines: [ContextLine], fallbackIndex: Int) -> String {
        var pieces: [String] = []
        if !field.ownLabel.isEmpty {
            pieces.append(field.ownLabel)
        }

        if let frame = field.frame {
            let nearby = textLines
                .filter { line in
                    guard let lineFrame = line.frame else {
                        return false
                    }
                    return isLikelyLabel(lineFrame: lineFrame, fieldFrame: frame)
                }
                .sorted { lhs, rhs in
                    distance(lhs.frame, frame) < distance(rhs.frame, frame)
                }
                .prefix(2)
                .map(\.text)
            pieces.append(contentsOf: nearby)
        }

        let label = pieces
            .map(normalized)
            .filter { !$0.isEmpty }
            .uniqued()
            .joined(separator: " / ")

        return label.isEmpty ? "Field \(fallbackIndex + 1)" : label
    }

    private func isLikelyLabel(lineFrame: CGRect, fieldFrame: CGRect) -> Bool {
        if lineFrame.intersects(fieldFrame) {
            return false
        }

        let verticalOverlap = max(0, min(lineFrame.maxY, fieldFrame.maxY) - max(lineFrame.minY, fieldFrame.minY))
        let horizontalOverlap = max(0, min(lineFrame.maxX, fieldFrame.maxX) - max(lineFrame.minX, fieldFrame.minX))
        let sameRowLeft = verticalOverlap > 0
            && lineFrame.maxX <= fieldFrame.minX + 12
            && fieldFrame.minX - lineFrame.maxX <= 360
        let above = lineFrame.maxY <= fieldFrame.minY + 10
            && fieldFrame.minY - lineFrame.maxY <= 90
            && (horizontalOverlap > 0 || abs(lineFrame.midX - fieldFrame.midX) <= max(fieldFrame.width, 280))

        return sameRowLeft || above
    }

    private func distance(_ lhs: CGRect?, _ rhs: CGRect) -> CGFloat {
        guard let lhs else {
            return CGFloat.greatestFiniteMagnitude
        }
        return hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
    }

    private func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
public protocol FormFillPlanning {
    func plan(_ request: FormFillRequest) async -> [FormFillSuggestion]
}

public struct LocalFormFillPlanner: FormFillPlanning {
    public init() {}

    public func plan(_ request: FormFillRequest) async -> [FormFillSuggestion] {
        request.fields.compactMap { field in
            guard field.isEmpty else {
                return nil
            }
            let label = [field.label, field.placeholder].filter { !$0.isEmpty }.joined(separator: " ")
            guard let value = request.userProfile.localFormFillValue(for: label) else {
                return nil
            }
            return FormFillSuggestion(
                fieldIndex: field.index,
                value: value,
                confidence: 0.86,
                reason: "profile"
            )
        }
    }
}

public final class FormFillPlanner: FormFillPlanning {
    private let configProvider: () -> VertexAIConfig
    private let localPlanner: FormFillPlanning
    private let urlSession: URLSession

    public init(
        configProvider: @escaping () -> VertexAIConfig = { VertexAIConfig.load() },
        localPlanner: FormFillPlanning = LocalFormFillPlanner(),
        urlSession: URLSession? = nil
    ) {
        self.configProvider = configProvider
        self.localPlanner = localPlanner
        self.urlSession = urlSession ?? NetworkRequestSafety.session
    }

    public func plan(_ request: FormFillRequest) async -> [FormFillSuggestion] {
        // Cancellation must not turn an abandoned network request into a fresh local
        // planning pass, which could otherwise produce suggestions after the caller has
        // already moved to another form or session.
        guard !Task.isCancelled else {
            return []
        }
        let config = configProvider()
        guard let proxyURL = config.proxyURL, !request.userProfile.isEmpty else {
            guard !Task.isCancelled else { return [] }
            return await localPlanner.plan(request)
        }

        do {
            let payload = CloudRunProxyRewriteRequest(
                systemInstruction: systemInstruction(),
                userPrompt: userPrompt(for: request)
            )
            var urlRequest = URLRequest(url: proxyURL)
            guard NetworkRequestSafety.isAllowedURL(proxyURL) else {
                guard !Task.isCancelled else { return [] }
                return await localPlanner.plan(request)
            }
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 20
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let proxyAuthToken = config.proxyAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !proxyAuthToken.isEmpty {
                urlRequest.setValue(proxyAuthToken, forHTTPHeaderField: "X-ResAI-Proxy-Key")
            }
            urlRequest.httpBody = try JSONEncoder().encode(payload)
            let requestForTransport = urlRequest
            let session = urlSession

            let (data, response) = try await NetworkRequestSafety.runWithTimeout(
                20,
                timeoutError: FormFillNetworkError.timeout
            ) {
                try await session.data(for: requestForTransport)
            }
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                guard !Task.isCancelled else { return [] }
                return await localPlanner.plan(request)
            }

            let decoded = try JSONDecoder().decode(CloudRunProxyRewriteResponse.self, from: data)
            if let finishReason = decoded.finishReason,
               finishReason.uppercased() != "STOP" {
                guard !Task.isCancelled else { return [] }
                return await localPlanner.plan(request)
            }
            let suggestions = try decodeSuggestions(from: decoded.text)
            let filtered = filteredSuggestions(suggestions, request: request)
            guard !Task.isCancelled else { return [] }
            return filtered.isEmpty ? await localPlanner.plan(request) : filtered
        } catch is CancellationError {
            return []
        } catch {
            guard !Task.isCancelled else { return [] }
            return await localPlanner.plan(request)
        }
    }

    private func systemInstruction() -> String {
        """
        あなたはフォーム入力候補を作るアシスタントです。
        与えられたプロフィールだけを根拠に、空欄のフォーム項目へ入れる候補をJSONで返してください。
        プロフィールにない事実、推測、架空の数値、架空のURL、架空の連絡先は絶対に作らないでください。
        パスワード、決済、認証コード、同意チェック、送信ボタンに関わる項目は必ず無視してください。
        既に値が入っている項目は無視してください。
        出力はJSONだけにしてください。
        """
    }

    private func userPrompt(for request: FormFillRequest) -> String {
        let fields = request.fields.map { field in
            """
            {
              "fieldIndex": \(field.index),
              "label": "\(escaped(field.label))",
              "placeholder": "\(escaped(field.placeholder))",
              "currentValue": "\(escaped(field.currentValue))",
              "role": "\(escaped(field.role))"
            }
            """
        }.joined(separator: ",\n")

        return """
        アプリ: \(request.appInfo.name)
        Bundle ID: \(request.appInfo.bundleIdentifier ?? "unknown")

        プロフィール:
        \(request.userProfile.formFillPromptText())

        フォーム項目:
        [
        \(fields)
        ]

        返却形式:
        {
          "items": [
            {
              "fieldIndex": 0,
              "value": "入力する文字列",
              "confidence": 0.0,
              "reason": "短い根拠"
            }
          ]
        }

        条件:
        - fieldIndexはフォーム項目に存在する番号だけ使う
        - confidenceは0.0から1.0
        - valueはプロフィールから直接分かる内容だけ
        - 不明な項目はitemsに含めない
        - 送信や同意は絶対に行わない
        """
    }

    private func decodeSuggestions(from rawText: String) throws -> [FormFillSuggestion] {
        let text = GeneratedReplySanitizer.sanitize(rawText)
        let jsonText = extractJSONObject(from: text) ?? text
        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(FormFillSuggestionResponse.self, from: data).items
    }

    private func filteredSuggestions(
        _ suggestions: [FormFillSuggestion],
        request: FormFillRequest
    ) -> [FormFillSuggestion] {
        let fieldsByIndex = Dictionary(uniqueKeysWithValues: request.fields.map { ($0.index, $0) })
        var seen = Set<Int>()

        return suggestions.compactMap { suggestion -> FormFillSuggestion? in
            guard seen.insert(suggestion.fieldIndex).inserted else {
                return nil
            }
            guard let field = fieldsByIndex[suggestion.fieldIndex], field.isEmpty else {
                return nil
            }
            let value = suggestion.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, suggestion.confidence >= 0.55 else {
                return nil
            }
            let label = "\(field.label) \(field.placeholder)".lowercased()
            guard !isSensitiveOrActionLikeLabel(label) else {
                return nil
            }
            return FormFillSuggestion(
                fieldIndex: suggestion.fieldIndex,
                value: value,
                confidence: suggestion.confidence,
                reason: suggestion.reason
            )
        }
    }

    private func isSensitiveOrActionLikeLabel(_ label: String) -> Bool {
        [
            "password",
            "passcode",
            "security code",
            "verification code",
            "auth code",
            "one-time code",
            "one time code",
            "otp",
            "card",
            "credit",
            "cvc",
            "cvv",
            "agree",
            "consent",
            "terms",
            "privacy policy",
            "submit",
            "send",
            "パスワード",
            "暗証",
            "認証コード",
            "確認コード",
            "ワンタイム",
            "カード",
            "クレジット",
            "同意",
            "規約",
            "プライバシー",
            "送信"
        ].contains { label.contains($0) }
    }

    private func extractJSONObject(from text: String) -> String? {
        guard
            let start = text.firstIndex(of: "{"),
            let end = text.lastIndex(of: "}"),
            start <= end
        else {
            return nil
        }
        return String(text[start...end])
    }

    private func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

private enum FormFillNetworkError: Error {
    case timeout
}

private struct FormFillSuggestionResponse: Decodable {
    var items: [FormFillSuggestion]
}

private struct RawFormField {
    var element: AXUIElement
    var role: String
    var frame: CGRect?
    var currentValue: String?
    var placeholder: String
    var ownLabel: String
}

private struct FormScanResult {
    var fields: [RawFormField]
    var textLines: [ContextLine]
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0.lowercased()).inserted }
    }
}
