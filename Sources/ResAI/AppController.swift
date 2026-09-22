import AppKit
import Foundation
import UniformTypeIdentifiers
import ResAICore

@MainActor
final class AppController: ObservableObject {
    @Published var config: VertexAIConfig
    @Published var mode: RewriteMode
    @Published var rewriteLanguage: RewriteLanguage
    @Published var lastStatus: String
    @Published var lastError: String?
    @Published var screenTextContextEnabled: Bool
    @Published var diagnosticTextPreviewLoggingEnabled: Bool
    @Published var userProfile: UserProfile
    @Published var userProfileEnabled: Bool
    @Published var shortcuts: AppShortcuts

    let clipboardHistory: ClipboardHistoryStore
    let voiceInput: VoiceInputController

    var onStatusChange: ((String) -> Void)?
    var onHUDMessage: ((HUDMessage) -> Void)?
    var onModeChange: ((RewriteMode) -> Void)?
    var onShortcutsChange: ((AppShortcuts) -> Void)?
    var onHideHUD: (() -> Void)?
    var onAccessibilityPermissionGranted: (() -> Void)?
    var shortcutDiagnosticsProvider: (() -> [String])?
    var shortcutsAreReady: (() -> Bool)?
    /// True when the menu-bar status item is under the notch or otherwise not visible.
    var menuBarIconHiddenByNotch = false

    var lastStatusDisplayName: String {
        statusDisplayName(for: lastStatus)
    }

    private let permissionManager: AccessibilityPermissionManager
    private let reader: AccessibilityReader
    private let formReader: FormReader
    private let formPlanner: FormFillPlanning
    private let replacer: TextReplacer
    private var rewriter: TextRewriting
    private var lastReplacement: LastReplacement?
    private var pendingFormFill: PendingFormFill?
    private var permissionMonitorTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?

    init(
        permissionManager: AccessibilityPermissionManager = AccessibilityPermissionManager(),
        reader: AccessibilityReader = AccessibilityReader(),
        formReader: FormReader = FormReader(),
        formPlanner: FormFillPlanning = FormFillPlanner(),
        replacer: TextReplacer = TextReplacer()
    ) {
        self.permissionManager = permissionManager
        self.reader = reader
        self.formReader = formReader
        self.formPlanner = formPlanner
        self.replacer = replacer
        self.config = VertexAIConfig.load()
        self.mode = .balanced
        self.rewriteLanguage = RewriteLanguage.load()
        self.lastStatus = "Ready"
        self.screenTextContextEnabled = UserDefaults.standard.object(
            forKey: PrivacyDefaultsKey.screenTextContextEnabled
        ) as? Bool ?? true
        self.diagnosticTextPreviewLoggingEnabled = UserDefaults.standard.bool(
            forKey: AppLog.textPreviewLoggingKey
        )
        self.userProfile = UserProfile.load()
        self.userProfileEnabled = UserDefaults.standard.object(
            forKey: UserProfile.DefaultsKey.isEnabled
        ) as? Bool ?? true
        self.shortcuts = AppShortcuts.load()
        self.clipboardHistory = ClipboardHistoryStore()
        self.rewriter = RewriteRouter(configProvider: { VertexAIConfig.load() })
        self.voiceInput = VoiceInputController(
            reader: reader,
            replacer: replacer,
            permissionManager: permissionManager,
            voicePill: VoicePillController()
        )
        voiceInput.onHUDMessage = { [weak self] message in
            self?.showHUD(message)
        }
        voiceInput.onHideHUD = { [weak self] in
            self?.onHideHUD?()
        }
        voiceInput.voiceTriggerDisplayNameProvider = { [weak self] in
            self?.shortcuts.voiceTrigger.displayName ?? AppShortcuts.defaults.voiceTrigger.displayName
        }
        voiceInput.onStatusChange = { [weak self] status in
            self?.setStatus(status)
        }
        voiceInput.canStartSession = { [weak self] in self?.operationTask == nil }
    }

    func rewriteFocusedDraft(
        mode modeOverride: RewriteMode? = nil,
        language languageOverride: RewriteLanguage? = nil
    ) {
        guard canBeginOperation else { return }
        AppLog.write("rewrite flow started")
        guard permissionManager.isTrusted else {
            AppLog.write("accessibility not trusted")
            requestAccessibilityPermission(showAlert: false)
            startPermissionMonitor()
            setStatus("Needs AX")
            showHUD(HUDMessage(
                title: "権限が未反映です",
                detail: "ResponseAiをオンにしてください",
                tone: .warning,
                duration: 4.0
            ))
            return
        }

        setStatus("Reading")
        showHUD(HUDMessage(title: "読取中", detail: "入力欄と文脈", tone: .loading, duration: nil))

        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            do {
                let composition = try await self.reader.captureFocusedComposition()
                try Task.checkCancellation()
                AppLog.write("captured focused composition app=\(composition.appInfo.name) draftLength=\(composition.draftText.count) contextLines=\(composition.contextLines.count) contextSource=\(composition.contextDiagnostics.captureLabel) axLines=\(composition.contextDiagnostics.accessibilityLineCount) ocrLines=\(composition.contextDiagnostics.screenTextLineCount) ocrAttempted=\(composition.contextDiagnostics.screenTextAttempted) ocrAuthorized=\(composition.contextDiagnostics.screenTextAuthorized)")
                AppLog.writeTextPreview(
                    "draft preview=\(self.logPreview(composition.draftText))",
                    redacted: "draft preview=(redacted)"
                )
                AppLog.writeTextPreview(
                    "context preview=\(self.logContextPreview(composition.contextLines))",
                    redacted: "context preview=(redacted)"
                )
                self.showHUD(HUDMessage(
                    title: "整形中",
                    detail: self.contextDetail(for: composition),
                    preview: self.contextPreviewSnippet(for: composition),
                    tone: .loading,
                    inputFrame: composition.inputFrame,
                    duration: nil
                ))
                let request = RewriteRequest(
                    appInfo: composition.appInfo,
                    draft: composition.draftText,
                    context: composition.contextText,
                    mode: modeOverride ?? self.mode,
                    language: languageOverride ?? self.rewriteLanguage,
                    userProfile: self.activeUserProfile
                )

                await self.performRewrite(request: request, composition: composition)
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.write("capture failed: \(error.localizedDescription)")
                self.presentError(error)
            }
        }
    }

    func focusedInputFrameForUI() -> CGRect? {
        guard permissionManager.isTrusted else {
            return nil
        }

        return try? reader.captureFocusedInputFrame()
    }

    func focusedInputTargetForUI() -> FocusedInputTarget? {
        guard permissionManager.isTrusted else {
            return nil
        }

        return try? reader.captureFocusedInputTarget()
    }

    func startClipboardHistoryMonitoring() {
        clipboardHistory.startMonitoring()
    }

    func shutDown() {
        operationTask?.cancel()
        permissionMonitorTask?.cancel()
        statusResetTask?.cancel()
        voiceInput.cancelActiveSession()
        voiceInput.cancelPendingCleanups()
        clipboardHistory.stopMonitoring()
    }

    func pasteClipboardHistoryItem(id: UUID, target: FocusedInputTarget?) {
        guard canBeginOperation else { return }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            guard await self.clipboardHistory.pasteItem(id: id, target: target) else {
                AppLog.write("clipboard history paste skipped: item or target unavailable, or operation cancelled")
                self.showHUD(HUDMessage(title: "貼り付けを中止しました", detail: "入力欄を確認して再実行", tone: .warning, duration: 2.5))
                return
            }
            self.setStatus("Ready")
        }
    }

    func clearClipboardHistory() {
        clipboardHistory.clear()
        showHUD(HUDMessage(
            title: "履歴を消去しました",
            detail: "クリップボード",
            tone: .success,
            duration: 1.8
        ))
    }

    func restoreLastDraft() {
        guard canBeginOperation else { return }
        operationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operationTask = nil }
            await self.restoreLastDraftAsync()
        }
    }

    private func restoreLastDraftAsync() async {
        if await voiceInput.revertLastCleanup() {
            return
        }

        guard let lastReplacement else {
            showHUD(HUDMessage(
                title: "戻せる下書きがありません",
                tone: .warning,
                duration: 1.8
            ))
            return
        }

        do {
            let result = try await replacer.replaceFocusedText(
                with: lastReplacement.originalText,
                in: lastReplacement.inputElement,
                inputFrame: lastReplacement.inputFrame,
                selectedTextRange: nil,
                preferClipboardPaste: lastReplacement.preferClipboardPaste,
                expectedOriginalText: lastReplacement.replacementText,
                requireFocusedTarget: true
            )
            AppLog.write("restore replacement method=\(result.method.rawValue) verified=\(result.verified)")
            if result.verified { self.lastReplacement = nil }
            setStatus("Restored")
            showHUD(HUDMessage(
                title: result.verified ? "戻しました" : "コピーしました",
                detail: lastReplacement.appName,
                preview: previewSnippet(lastReplacement.originalText),
                tone: result.verified ? .success : .warning,
                inputFrame: lastReplacement.inputFrame,
                duration: result.verified ? 2.0 : 4.0
            ))
        } catch {
            AppLog.write("restore failed: \(error.localizedDescription)")
            presentError(error)
        }
    }

    func fillFormFromProfile() {
        guard canBeginOperation else { return }
        AppLog.write("form fill requested")
        guard permissionManager.isTrusted else {
            AppLog.write("form fill blocked: accessibility not trusted")
            requestAccessibilityPermission(showAlert: false)
            startPermissionMonitor()
            setStatus("Needs AX")
            showHUD(HUDMessage(
                title: "権限が未反映です",
                detail: "ResponseAiをオンにしてください",
                tone: .warning,
                duration: 4.0
            ))
            return
        }

        if let pendingFormFill, pendingFormFill.isFresh {
            operationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.operationTask = nil }
                await self.applyPendingFormFill(pendingFormFill)
            }
            return
        }

        guard !userProfile.isEmpty else {
            setStatus("Profile")
            showHUD(HUDMessage(
                title: "プロフィールが空です",
                detail: "設定 > プロフィール",
                preview: "フォーム入力には名前、会社、メール、サービス説明などを登録してください。",
                tone: .warning,
                duration: 4.0
            ))
            return
        }

        setStatus("Form")
        showHUD(HUDMessage(
            title: "フォーム読取中",
            detail: "入力欄とラベル",
            tone: .loading,
            duration: nil
        ))

        operationTask = Task { @MainActor [weak self] in
          guard let self else { return }
          defer { self.operationTask = nil }
          do {
            let capturedForm = try await formReader.captureFocusedForm()
            try Task.checkCancellation()
            AppLog.write("captured form app=\(capturedForm.appInfo.name) fields=\(capturedForm.fields.count)")
            guard !capturedForm.fields.isEmpty else {
                showHUD(HUDMessage(
                    title: "入力欄が見つかりません",
                    detail: capturedForm.appInfo.name,
                    tone: .warning,
                    duration: 3.0
                ))
                return
            }

            await prepareFormFill(capturedForm)
          } catch {
            guard !Task.isCancelled else { return }
            AppLog.write("form capture failed: \(error.localizedDescription)")
            presentError(error)
          }
        }
    }

    func setMode(_ mode: RewriteMode) {
        self.mode = mode
        onModeChange?(mode)
        setStatus(mode.displayName)
        showHUD(HUDMessage(
            title: "モード",
            detail: mode.displayName,
            tone: .idle,
            duration: 1.2
        ))
    }

    func setRewriteLanguage(_ language: RewriteLanguage) {
        self.rewriteLanguage = language
        language.save()
        setStatus(language.displayName)
        showHUD(HUDMessage(
            title: "返信言語",
            detail: language.displayName,
            tone: .idle,
            duration: 1.2
        ))
    }

    func saveConfig() {
        do { try config.save() }
        catch { presentError(error); return }
        rewriteLanguage.save()
        savePrivacySettings()
        saveUserProfile()
        saveShortcuts(showHUD: false)
        voiceInput.saveSettings()
        rewriter = RewriteRouter(configProvider: { [config] in config })
        setStatus("Saved")
    }

    func saveShortcuts(showHUD: Bool = true) {
        let sanitized = shortcuts.sanitized()
        if sanitized != shortcuts {
            shortcuts = sanitized
        }
        sanitized.save()
        onShortcutsChange?(sanitized)
        AppLog.write("shortcuts saved rewrite=\(sanitized.rewrite.displayName) restore=\(sanitized.restore.displayName) form=\(sanitized.formFill.displayName) menu=\(sanitized.quickMenu.displayName) voice=\(sanitized.voiceTrigger.displayName)")
        if showHUD {
            setStatus("Shortcuts")
            self.showHUD(HUDMessage(
                title: "ショートカットを保存しました",
                detail: "⌘ + ⇧ は固定",
                preview: shortcutSummary(for: sanitized),
                tone: .success,
                duration: 2.6
            ))
        }
    }

    func saveUserProfile() {
        userProfile.save()
        UserDefaults.standard.set(userProfileEnabled, forKey: UserProfile.DefaultsKey.isEnabled)
    }

    func exportUserProfile() {
        let panel = NSSavePanel()
        panel.title = "ResponseAi プロフィールを書き出し"
        panel.nameFieldStringValue = "responseai-profile.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(userProfile)
            try data.write(to: url, options: .atomic)
            setStatus("Exported")
            showHUD(HUDMessage(
                title: "プロフィールを書き出しました",
                detail: url.lastPathComponent,
                tone: .success,
                duration: 2.2
            ))
        } catch {
            AppLog.write("profile export failed: \(error.localizedDescription)")
            presentError(error)
        }
    }

    func importUserProfile() {
        let panel = NSOpenPanel()
        panel.title = "ResponseAi プロフィールを読み込み"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(UserProfile.self, from: data)
            userProfile = imported
            userProfileEnabled = true
            saveUserProfile()
            setStatus("Imported")
            showHUD(HUDMessage(
                title: "プロフィールを読み込みました",
                detail: url.lastPathComponent,
                tone: .success,
                duration: 2.2
            ))
        } catch {
            AppLog.write("profile import failed: \(error.localizedDescription)")
            presentError(error)
        }
    }

    func clearUserProfile() {
        userProfile = UserProfile()
        saveUserProfile()
        setStatus("Cleared")
        showHUD(HUDMessage(
            title: "プロフィールを空にしました",
            tone: .success,
            duration: 1.8
        ))
    }

    private var activeUserProfile: UserProfile {
        userProfileEnabled ? userProfile : UserProfile()
    }

    func savePrivacySettings() {
        UserDefaults.standard.set(
            screenTextContextEnabled,
            forKey: PrivacyDefaultsKey.screenTextContextEnabled
        )
        UserDefaults.standard.set(
            diagnosticTextPreviewLoggingEnabled,
            forKey: AppLog.textPreviewLoggingKey
        )
    }

    func requestAccessibilityPermissionIfNeeded() {
        guard !permissionManager.isTrusted else {
            AppLog.write("accessibility trusted")
            return
        }
        AppLog.write("accessibility prompt requested on launch")
        _ = permissionManager.requestPermissionPrompt()
        openAccessibilitySettings()
        startPermissionMonitor()
    }

    func requestAccessibilityPermission(showAlert: Bool = true) {
        _ = permissionManager.requestPermissionPrompt()
        openAccessibilitySettings()
        startPermissionMonitor()
        if showAlert {
            presentInformationalAlert(
                title: "アクセシビリティ権限",
                message: "システム設定 > プライバシーとセキュリティ > アクセシビリティでResponseAiをオンにしてから、もう一度実行してください。"
            )
        }
    }

    func requestScreenRecordingPermission() {
        if ScreenTextReader.hasScreenCaptureAccess() {
            showHUD(HUDMessage(
                title: "画面収録OK",
                detail: "ブラウザ文脈を読めます",
                tone: .success,
                duration: 2.2
            ))
            return
        }

        _ = ScreenTextReader.requestScreenCaptureAccess()
        openScreenRecordingSettings()
        showHUD(HUDMessage(
            title: "画面収録をオン",
            detail: "ResponseAiを許可してください",
            preview: "FacebookやGmailなど、アクセシビリティだけでは会話が読みにくい画面で使います。",
            tone: .warning,
            duration: 5.0
        ))
    }

    func runReadinessCheck() {
        guard canBeginOperation else { return }
        setStatus("Checking")
        showHUD(HUDMessage(
            title: "確認中",
            detail: "権限とAI接続",
            tone: .loading,
            duration: nil
        ))

        operationTask = Task { @MainActor in
            defer { operationTask = nil }
            await performReadinessCheck()
        }
    }

    func showStartupStatus() {
        let trusted = permissionManager.isTrusted
        let ready = trusted && (shortcutsAreReady?() ?? false)
        showHUD(HUDMessage(
            title: ready ? "ResponseAi 起動中" : "ResponseAi 要確認",
            detail: !trusted ? "アクセシビリティをオン" : (ready ? shortcuts.rewrite.displayName : "メニューからショートカットを修復"),
            tone: ready ? .success : .warning,
            duration: ready ? 2.2 : 4.0
        ))
    }

    func presentError(_ error: Error, showAlert: Bool = false) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        AppLog.write("error: \(message)")
        setStatus("Error")
        showHUD(HUDMessage(
            title: "失敗しました",
            detail: nil,
            preview: message,
            tone: .error,
            duration: 3.5
        ))
        if showAlert {
            presentInformationalAlert(title: "ResponseAi エラー", message: message)
        }
    }

    private func performRewrite(request: RewriteRequest, composition: FocusedComposition) async {
        setStatus("AI")

        do {
            let result = try await rewriter.rewrite(request)
            try Task.checkCancellation()
            guard let originalValue = composition.originalFieldValue,
                  let replacementValue = CapturedTextEditPlan.valueByReplacingSelection(
                    originalValue: originalValue,
                    selectedRange: composition.selectedTextRange.flatMap { $0.length > 0 ? $0 : nil },
                    replacementText: result.text
                  ) else {
                throw InputProtectionError.unreadableOriginal
            }
            AppLog.writeTextPreview(
                "rewrite result source=\(result.source.rawValue) length=\(result.text.count) preview=\(logPreview(result.text))",
                redacted: "rewrite result source=\(result.source.rawValue) length=\(result.text.count) preview=(redacted)"
            )
            let preferClipboardPaste = shouldPreferClipboardPaste(for: composition.appInfo)
            let replacementResult = try await replacer.replaceFocusedText(
                with: replacementValue,
                in: composition.inputElement,
                inputFrame: composition.inputFrame,
                selectedTextRange: nil,
                preferClipboardPaste: preferClipboardPaste,
                expectedOriginalText: originalValue,
                requireFocusedTarget: true
            )
            AppLog.write("replacement method=\(replacementResult.method.rawValue) verified=\(replacementResult.verified) preferClipboardPaste=\(preferClipboardPaste)")

            if replacementResult.verified {
                lastReplacement = LastReplacement(
                    inputElement: composition.inputElement,
                    inputFrame: composition.inputFrame,
                    selectedTextRange: composition.selectedTextRange,
                    originalText: originalValue,
                    replacementText: replacementValue,
                    appName: composition.appInfo.name,
                    preferClipboardPaste: preferClipboardPaste
                )
                setStatus(result.source == .localPreview ? "Preview" : "Done")
                showHUD(HUDMessage(
                    title: result.source == .localPreview ? "デモ変換しました" : "差し替えました",
                    detail: composition.appInfo.name,
                    preview: previewSnippet(result.text),
                    tone: result.source == .localPreview ? .warning : .success,
                    inputFrame: composition.inputFrame,
                    duration: 2.8
                ))
            } else {
                lastReplacement = nil
                setStatus("Copied")
                showHUD(HUDMessage(
                    title: "コピーしました",
                    detail: "入力できなかったため手動で貼り付け",
                    preview: previewSnippet(result.text),
                    tone: .warning,
                    inputFrame: composition.inputFrame,
                    duration: 4.5
                ))
            }
        } catch {
            guard !Task.isCancelled else { return }
            AppLog.write("rewrite failed: \(error.localizedDescription)")
            presentError(error)
        }
    }

    private func prepareFormFill(_ capturedForm: CapturedForm) async {
        let request = FormFillRequest(
            appInfo: capturedForm.appInfo,
            fields: capturedForm.snapshots,
            userProfile: userProfile
        )
        let suggestions = await formPlanner.plan(request)
        guard !Task.isCancelled else { return }
        let fieldsByIndex = Dictionary(uniqueKeysWithValues: capturedForm.fields.map { ($0.snapshot.index, $0) })
        let items = suggestions.compactMap { suggestion -> PendingFormFillItem? in
            guard let field = fieldsByIndex[suggestion.fieldIndex] else {
                return nil
            }
            return PendingFormFillItem(field: field, suggestion: suggestion)
        }

        guard !items.isEmpty else {
            pendingFormFill = nil
            setStatus("No Fill")
            showHUD(HUDMessage(
                title: "埋められる項目がありません",
                detail: "\(capturedForm.fields.count)項目を確認",
                preview: "プロフィールにない内容は入力しません。既に値がある欄、パスワード、決済、同意系もスキップします。",
                tone: .warning,
                duration: 5.0
            ))
            return
        }

        pendingFormFill = PendingFormFill(
            appInfo: capturedForm.appInfo,
            items: items,
            createdAt: Date()
        )
        setStatus("Confirm")
        showHUD(HUDMessage(
            title: "入力候補 \(items.count)件",
            detail: "もう一度 \(shortcuts.formFill.displayName)",
            preview: formFillPreview(items),
            tone: .idle,
            duration: 8.0
        ))
    }

    private func applyPendingFormFill(_ pending: PendingFormFill) async {
        pendingFormFill = nil
        guard pending.isFresh,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.appInfo.processIdentifier,
              confirmFormFill(pending) else {
            setStatus("Ready")
            onHideHUD?()
            return
        }
        if let pid = pending.appInfo.processIdentifier {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        setStatus("Filling")
        showHUD(HUDMessage(
            title: "入力中",
            detail: "\(pending.items.count)件",
            tone: .loading,
            duration: nil
        ))

        let preferClipboardPaste = shouldPreferClipboardPaste(for: pending.appInfo)
        var verifiedCount = 0
        var copiedCount = 0
        var failedCount = 0

        for item in pending.items {
            do {
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.appInfo.processIdentifier,
                      formReader.revalidateEmpty(item.field) else {
                    failedCount += pending.items.count - verifiedCount - copiedCount - failedCount
                    break
                }
                let result = try await replacer.replaceFocusedText(
                    with: item.suggestion.value,
                    in: item.field.element,
                    inputFrame: item.field.frame,
                    selectedTextRange: nil,
                    preferClipboardPaste: preferClipboardPaste,
                    expectedOriginalText: item.field.snapshot.currentValue
                )
                if result.verified {
                    verifiedCount += 1
                } else {
                    copiedCount += 1
                }
                AppLog.write("form fill field=\(item.field.snapshot.index) method=\(result.method.rawValue) verified=\(result.verified)")
            } catch {
                failedCount += 1
                AppLog.write("form fill field=\(item.field.snapshot.index) failed: \(error.localizedDescription)")
            }
        }

        let tone: HUDMessage.Tone = failedCount == 0 && copiedCount == 0 ? .success : .warning
        setStatus(tone == .success ? "Filled" : "Partial")
        showHUD(HUDMessage(
            title: tone == .success ? "入力しました" : "一部のみ入力",
            detail: "\(verifiedCount)件完了",
            preview: [
                copiedCount > 0 ? "\(copiedCount)件は確認できませんでした。最後の値はクリップボードに残っている可能性があります。" : nil,
                failedCount > 0 ? "\(failedCount)件は失敗しました。" : nil,
                "送信ボタンは押していません。"
            ].compactMap { $0 }.joined(separator: "\n"),
            tone: tone,
            duration: 5.0
        ))
    }

    private func confirmFormFill(_ pending: PendingFormFill) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(pending.items.count)件の入力内容を確認"
        alert.informativeText = "\(pending.appInfo.name)の空欄にのみ入力します。送信はしません。"
        alert.addButton(withTitle: "入力する").keyEquivalent = ""
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\u{1b}"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: 13)
        text.string = pending.items.map { "\($0.field.snapshot.label)\n\($0.suggestion.value)" }.joined(separator: "\n\n")
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func setStatus(_ status: String) {
        statusResetTask?.cancel()
        lastStatus = status
        onStatusChange?(status == "Ready" ? "ResponseAi" : "ResponseAi \(statusDisplayName(for: status))")

        let persistent = ["Ready", "Needs AX", "Reading", "AI", "Form", "Filling", "Listening", "Finishing", "Checking", "Check", "Error", "Confirm"]
        if !persistent.contains(status) {
            statusResetTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.setStatus("Ready")
            }
        }
    }

    private var canBeginOperation: Bool {
        guard operationTask == nil, !voiceInput.isBusy else {
            AppLog.write("input operation skipped: another operation is active")
            return false
        }
        voiceInput.cancelPendingCleanups()
        return true
    }

    private func statusDisplayName(for status: String) -> String {
        switch status {
        case "Ready":
            "待機中"
        case "Needs AX":
            "権限待ち"
        case "Reading":
            "読取中"
        case "AI":
            "AI処理中"
        case "Restored":
            "復元済み"
        case "Profile":
            "プロフィール"
        case "Form":
            "フォーム"
        case "Saved":
            "保存済み"
        case "Shortcuts":
            "ショートカット"
        case "Exported":
            "書き出し済み"
        case "Imported":
            "読み込み済み"
        case "Cleared":
            "クリア済み"
        case "Checking":
            "確認中"
        case "Check":
            "要確認"
        case "Error":
            "エラー"
        case "Preview":
            "デモ"
        case "Done":
            "完了"
        case "Copied":
            "コピー済み"
        case "Pasted":
            "貼り付け済み"
        case "No Fill":
            "入力なし"
        case "Confirm":
            "確認待ち"
        case "Filling":
            "入力中"
        case "Filled":
            "入力済み"
        case "Partial":
            "一部入力"
        case "Listening":
            "聞き取り中"
        case "Finishing":
            "確定中"
        case "Cleaned":
            "整え済み"
        default:
            status
        }
    }

    private func presentInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showHUD(_ message: HUDMessage) {
        voiceInput.voicePill.hide(animated: false)
        onHUDMessage?(message)
    }

    private func performReadinessCheck() async {
        let accessibilityOK = permissionManager.isTrusted
        let screenRecordingOK = ScreenTextReader.hasScreenCaptureAccess()
        let loadedConfig = VertexAIConfig.load()
        let proxyStatus = await proxyHealthStatus(for: loadedConfig)
        let profileStatus = userProfileEnabled
            ? (userProfile.isEmpty ? "プロフィール オン / 未入力" : "プロフィール オン")
            : "プロフィール オフ"

        let allRequiredOK = accessibilityOK && proxyStatus.isUsable && (shortcutsAreReady?() ?? false) && voiceInput.isReady
        let menuBarIconLine = menuBarIconHiddenByNotch
            ? "隠れています メニューバーアイコン（ノッチ）"
            : "OK メニューバーアイコン"
        let lines = [
            "\(accessibilityOK ? "OK" : "未許可") アクセシビリティ",
            "\(screenRecordingOK ? "OK" : "未許可") 画面収録",
            "\(proxyStatus.label) AIプロキシ",
            profileStatus
        ] + (shortcutDiagnosticsProvider?() ?? ["未確認 ショートカット"]) + voiceInput.readinessLines(voiceShortcut: shortcuts.voiceTrigger.displayName) + [
            menuBarIconLine,
            shortcutSummary(for: shortcuts)
        ]

        AppLog.write("readiness check ax=\(accessibilityOK) screen=\(screenRecordingOK) proxy=\(proxyStatus.label) profile=\(profileStatus) menuBar=\(menuBarIconHiddenByNotch ? "notch-hidden" : "ok")")
        setStatus(allRequiredOK ? "Ready" : "Check")
        onHideHUD?()
        // A three-line HUD truncates the actual microphone/hotkey diagnostics.
        // This is explicitly opened by the user, so show the complete report.
        presentInformationalAlert(
            title: allRequiredOK ? "準備OK" : "ResponseAi 要確認",
            message: lines.joined(separator: "\n")
        )
    }

    private func proxyHealthStatus(for config: VertexAIConfig) async -> ProxyHealthStatus {
        guard let rewriteURL = config.proxyURL else {
            let hasDirectToken = (try? EnvironmentAccessTokenProvider().accessToken()) != nil
            return ProxyHealthStatus(label: hasDirectToken ? "直接Vertex（接続未確認）" : "プレビュー（AI未接続）", isUsable: false)
        }
        guard NetworkRequestSafety.isAllowedURL(rewriteURL) else {
            return ProxyHealthStatus(label: "HTTPS URLを設定", isUsable: false)
        }

        var components = URLComponents(url: rewriteURL, resolvingAgainstBaseURL: false)
        components?.path = "/healthz"
        components?.query = nil
        guard let healthURL = components?.url else {
            return ProxyHealthStatus(label: "NG", isUsable: false)
        }

        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6

        do {
            let (_, response) = try await NetworkRequestSafety.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ProxyHealthStatus(label: "NG", isUsable: false)
            }
            if (200..<300).contains(httpResponse.statusCode) {
                return await rewriteEndpointProbeStatus(for: config, rewriteURL: rewriteURL)
            }
            if httpResponse.statusCode != 404 {
                return ProxyHealthStatus(label: "HTTP \(httpResponse.statusCode)", isUsable: false)
            }
        } catch {
            AppLog.write("proxy health failed: \(error.localizedDescription)")
        }

        return await rewriteEndpointProbeStatus(for: config, rewriteURL: rewriteURL)
    }

    private func rewriteEndpointProbeStatus(
        for config: VertexAIConfig,
        rewriteURL: URL
    ) async -> ProxyHealthStatus {
        var request = URLRequest(url: rewriteURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let proxyAuthToken = config.proxyAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !proxyAuthToken.isEmpty {
            request.setValue(proxyAuthToken, forHTTPHeaderField: "X-ResAI-Proxy-Key")
        }
        request.httpBody = Data("{}".utf8)

        do {
            let (_, response) = try await NetworkRequestSafety.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ProxyHealthStatus(label: "NG", isUsable: false)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return ProxyHealthStatus(label: "OK", isUsable: true)
            case 400:
                return ProxyHealthStatus(label: "OK", isUsable: true)
            case 401, 403:
                return ProxyHealthStatus(label: "認証NG", isUsable: false)
            default:
                return ProxyHealthStatus(label: "HTTP \(httpResponse.statusCode)", isUsable: false)
            }
        } catch {
            AppLog.write("proxy rewrite probe failed: \(error.localizedDescription)")
            return ProxyHealthStatus(label: "NG", isUsable: false)
        }
    }

    private func startPermissionMonitor() {
        permissionMonitorTask?.cancel()
        permissionMonitorTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for attempt in 1...120 {
                guard !Task.isCancelled else { return }
                if self.permissionManager.isTrusted {
                    self.onAccessibilityPermissionGranted?()
                    AppLog.write("accessibility trusted after monitor attempt=\(attempt)")
                    self.showHUD(HUDMessage(
                        title: "権限OK",
                        detail: self.shortcuts.rewrite.displayName,
                        tone: .success,
                        duration: 2.4
                    ))
                    self.setStatus((self.shortcutsAreReady?() ?? false) ? "Ready" : "Check")
                    self.permissionMonitorTask = nil
                    return
                }

                if attempt == 1 || attempt % 10 == 0 {
                    AppLog.write("accessibility still not trusted attempt=\(attempt)")
                }

                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }

            AppLog.write("accessibility monitor timed out")
            self.showHUD(HUDMessage(
                title: "権限がまだ未反映です",
                detail: "権限をオンにして「ショートカットを修復」",
                tone: .warning,
                duration: 5.0
            ))
            self.permissionMonitorTask = nil
        }
    }

    private func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                AppLog.write("opened accessibility settings: \(urlString)")
                return
            }
        }
    }

    private func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                AppLog.write("opened screen recording settings: \(urlString)")
                return
            }
        }
    }

    private func previewSnippet(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard normalized.count > 150 else {
            return normalized
        }

        return String(normalized.prefix(150)) + "..."
    }

    private func formFillPreview(_ items: [PendingFormFillItem]) -> String {
        items.prefix(5).map { item in
            "\(previewSnippet(item.field.snapshot.label)): \(previewSnippet(item.suggestion.value))"
        }
        .joined(separator: "\n")
    }

    private func shortcutSummary(for shortcuts: AppShortcuts) -> String {
        "音声 \(shortcuts.voiceTrigger.displayName) / 返信 \(shortcuts.rewrite.displayName) / メニュー \(shortcuts.quickMenu.displayName) / フォーム \(shortcuts.formFill.displayName) / 復元 \(shortcuts.restore.displayName)"
    }

    private func contextDetail(for composition: FocusedComposition) -> String {
        guard !composition.contextLines.isEmpty else {
            return "下書きのみ"
        }

        return "文脈 \(composition.contextLines.count)行 / \(composition.contextDiagnostics.captureLabel)"
    }

    private func contextPreviewSnippet(for composition: FocusedComposition) -> String? {
        let relevantLines = composition.contextLines.suffix(3).map(\.text)
        guard !relevantLines.isEmpty else {
            if composition.contextDiagnostics.screenTextAttempted,
               !composition.contextDiagnostics.screenTextAuthorized {
                return "文脈は読めていません。ブラウザでは画面収録をオンにすると入力欄の上の会話を読めます。"
            }
            return "文脈は読めていません。下書きだけで整形します。"
        }

        return relevantLines
            .map { "・\(previewSnippet($0))" }
            .joined(separator: "\n")
    }

    private func logContextPreview(_ lines: [ContextLine]) -> String {
        guard !lines.isEmpty else {
            return "(none)"
        }

        return lines.enumerated()
            .map { index, line in "\(index + 1):\(logPreview(line.text))" }
            .joined(separator: " | ")
    }

    private func logPreview(_ text: String) -> String {
        let normalized = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard normalized.count > 120 else {
            return normalized.isEmpty ? "(empty)" : normalized
        }

        return String(normalized.prefix(120)) + "..."
    }

    private func shouldPreferClipboardPaste(for appInfo: AppInfo) -> Bool {
        AppAutomationPolicy.prefersClipboardPaste(for: appInfo)
    }
}

enum PrivacyDefaultsKey {
    static let screenTextContextEnabled = "privacy.screenTextContextEnabled"
}

private struct LastReplacement {
    var inputElement: AXUIElement
    var inputFrame: CGRect?
    var selectedTextRange: CFRange?
    var originalText: String
    var replacementText: String
    var appName: String
    var preferClipboardPaste: Bool
}

private struct PendingFormFill {
    var appInfo: AppInfo
    var items: [PendingFormFillItem]
    var createdAt: Date

    var isFresh: Bool {
        Date().timeIntervalSince(createdAt) <= 20
    }
}

private struct PendingFormFillItem {
    var field: CapturedFormField
    var suggestion: FormFillSuggestion
}

private struct ProxyHealthStatus {
    var label: String
    var isUsable: Bool
}

private enum InputProtectionError: LocalizedError {
    case unreadableOriginal
    var errorDescription: String? {
        "元の文章を安全に確認できないため、自動置換を中止しました。入力欄を確認して再実行してください。"
    }
}
