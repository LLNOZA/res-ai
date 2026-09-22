import AppKit
import Foundation
import ResAICore

/// Hold-to-talk voice input with tap-to-toggle fallback: on-device transcription is inserted at
/// the caret, then an optional Gemini cleanup pass swaps only the inserted text afterwards.
@MainActor
final class VoiceInputController: ObservableObject {
    @Published var settings: VoiceInputSettings
    @Published var dictionary: UserDictionary
    @Published var geminiAPIKey: String
    @Published private(set) var isListening = false
    @Published private(set) var lastConnectionTestResult: String?

    var onHUDMessage: ((HUDMessage) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onHideHUD: (() -> Void)?
    /// App-level work (rewrite/form/restore) can temporarily reserve the input
    /// surface.  The default keeps this controller usable in isolation/tests.
    var canStartSession: () -> Bool = { true }
    let voicePill: VoicePillController
    var voiceTriggerDisplayNameProvider: () -> String = {
        AppShortcuts.load().voiceTrigger.displayName
    }

    private enum Phase {
        case idle
        case listening
        case finishing
    }

    private let engine: any SpeechDictating
    private let reader: AccessibilityReader
    private let replacer: TextReplacer
    private let permissionManager: AccessibilityPermissionManager
    private var phase: Phase = .idle
    private var sessionLifecycle = VoiceSessionLifecycle()
    private var activeSessionID: VoiceSessionID?
    /// The recording session ends before its optional Gemini cleanup.  Keep a
    /// separate identity so normal completion does not discard a valid cleanup
    /// callback, while a new/cancelled session still invalidates it.
    private var cleanupSessionID: VoiceSessionID?
    private var target: FocusedInputTarget?
    private var contextCaptureTask: Task<[String], Never>?
    private var pendingCleanups: [UUID: Task<Void, Never>] = [:]
    private var pendingCleanupOrder: [UUID] = []
    private var lastInsertion: TextInsertionRecord?
    private var latestInsertionID: UUID?
    private var lastCleanup: (record: TextInsertionRecord, rawText: String, at: Date)?
    private var keyboardSwapGuard: KeyboardSwapGuard?
    private var activation = VoiceActivationStateMachine()
    private let escapeMonitor = EscapeKeyMonitor()
    private var hotKeyPressedAt: TimeInterval?
    private var currentTranscriptPreview: String?
    private var currentAudioLevel: Float = 0
    private var sessionHint: String?
    private var finishTask: Task<Void, Never>?

    var isBusy: Bool { phase != .idle }

    var isReady: Bool {
        isSupported
            && !isBusy
            && engine.isReady
            && MicrophonePermission.status() == .granted
    }

    init(
        reader: AccessibilityReader,
        replacer: TextReplacer,
        permissionManager: AccessibilityPermissionManager,
        voicePill: VoicePillController = VoicePillController(),
        engine: (any SpeechDictating)? = nil
    ) {
        self.reader = reader
        self.replacer = replacer
        self.permissionManager = permissionManager
        self.voicePill = voicePill
        self.engine = engine ?? SpeechDictationEngineFactory.make()
        self.settings = VoiceInputSettings.load()
        self.dictionary = UserDictionary.load()
        self.geminiAPIKey = GeminiAPIKeyStore.load() ?? ""
    }

    var isSupported: Bool {
        SpeechDictationEngineFactory.isSupported
    }

    var hasGeminiKey: Bool {
        !geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Downloads/reserves the on-device model ahead of the first press so start is near-instant.
    func warmUp() {
        let locale = Locale(identifier: settings.localeIdentifier)
        Task { @MainActor in
            do {
                try await engine.prepare(locale: locale)
                AppLog.write("voice engine warmed up engine=\(engine.engineName) locale=\(locale.identifier)")
            } catch {
                AppLog.write("voice engine warm-up failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Hotkey entry points

    func hotKeyPressed() {
        if phase == .idle, !canStartSession() {
            resetActivationToIdle()
            return
        }
        hotKeyPressedAt = now()
        applyActivation(activation.handle(.keyDown(at: now()), mode: settings.activationMode))
    }

    func hotKeyReleased() {
        let action = activation.handle(.keyUp(at: now()), mode: settings.activationMode)
        applyActivation(action)
        if action == .none, case .toggled = activation.state, phase == .listening {
            showListeningPill()
        }
    }

    func cancelListening() {
        cancelActiveSession()
    }

    /// Cancels both a listening session and a session whose engine is still
    /// preparing/finalizing.  Escape and app-level recovery use this entry point
    /// so an in-flight `start` cannot resurrect the microphone later.
    func cancelActiveSession() {
        guard phase != .idle || activeSessionID != nil || cleanupSessionID != nil || engine.isRunning else {
            return
        }
        let hadSession = phase != .idle || activeSessionID != nil || cleanupSessionID != nil || engine.isRunning
        let shouldCancelEngine = phase != .idle || activeSessionID != nil || engine.isRunning
        cancelPendingCleanups()
        finishTask?.cancel()
        finishTask = nil
        startTask?.cancel()
        startTask = nil
        sessionLifecycle.invalidate()
        activeSessionID = nil
        if shouldCancelEngine {
            engine.cancel()
        }
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        phase = .idle
        setListening(false)
        resetActivationToIdle()
        setStatus("Ready")
        if hadSession {
            showHUD(HUDMessage(
                title: "音声入力を中止しました",
                tone: .idle,
                duration: 1.6
            ))
        }
    }

    /// Cancels in-flight Gemini cleanups. Called from Escape and app termination.
    func cancelPendingCleanups() {
        for task in pendingCleanups.values {
            task.cancel()
        }
        pendingCleanups.removeAll()
        pendingCleanupOrder.removeAll()
        cleanupSessionID = nil
    }

    /// Replaces the last Gemini cleanup with the raw inserted transcript when it is still within 60s.
    func revertLastCleanup() async -> Bool {
        guard let lastCleanup, Date().timeIntervalSince(lastCleanup.at) < 60 else {
            return false
        }

        guard let updated = await swapInsertedText(
            lastCleanup.record,
            with: lastCleanup.rawText,
            logPrefix: "voice revert"
        ) else {
            return false
        }

        lastInsertion = updated
        self.lastCleanup = nil
        stopKeyboardSwapGuard()
        setStatus("Restored")
        showHUD(HUDMessage(
            title: "整えを取り消しました",
            tone: .success,
            inputFrame: updated.inputFrame,
            duration: 1.8
        ))
        return true
    }

    // MARK: - Session

    private func startListening() {
        guard phase == .idle else {
            return
        }
        guard canStartSession() else {
            // The app-level operation may have become busy between the
            // hotkey preflight and this activation callback. Do not leave the
            // activation state armed, or the next press can be interpreted as
            // a confirmation instead of a fresh start.
            resetActivationToIdle()
            return
        }
        guard permissionManager.isTrusted else {
            resetActivationToIdle()
            showHUD(HUDMessage(
                title: "権限が未反映です",
                detail: "アクセシビリティをオン",
                tone: .warning,
                duration: 3.0
            ))
            return
        }

        let capturedTarget: FocusedInputTarget
        do {
            capturedTarget = try reader.captureFocusedInputTarget()
        } catch {
            AppLog.write("voice: focused input unavailable: \(error.localizedDescription)")
            resetActivationToIdle()
            showHUD(HUDMessage(
                title: "入力欄が見つかりません",
                detail: "文字を入れたい欄をクリック",
                tone: .warning,
                duration: 2.6
            ))
            return
        }

        let sessionID = sessionLifecycle.begin()
        activeSessionID = sessionID
        cancelPendingCleanups()
        finishTask?.cancel()
        finishTask = nil
        latestInsertionID = nil
        target = capturedTarget
        lastInsertion = nil
        lastCleanup = nil
        stopKeyboardSwapGuard()
        currentTranscriptPreview = nil
        currentAudioLevel = 0
        sessionHint = pillHint
        phase = .listening
        setListening(true)
        setStatus("Listening")
        onHideHUD?()
        showListeningPill()

        if settings.cleanupEnabled, settings.includeScreenContext {
            startContextCapture()
        }

        engine.onTranscriptUpdate = { [weak self] transcript in
            guard let self else { return }
            guard self.activeSessionID == sessionID else { return }
            self.handleTranscriptUpdate(transcript, sessionID: sessionID)
        }
        engine.onCaptureStarted = { [weak self] in
            guard let self else { return }
            guard self.activeSessionID == sessionID else { return }
            AppLog.write("voice mic capturing elapsedMs=\(self.elapsedMsSinceHotKey())")
        }
        engine.onAudioLevel = { [weak self] level in
            guard let self, self.activeSessionID == sessionID else { return }
            self.handleAudioLevel(level, sessionID: sessionID)
        }
        engine.onError = { [weak self] error in
            guard let self, self.activeSessionID == sessionID else { return }
            self.handleEngineError(error, sessionID: sessionID)
        }

        if settings.cleanupEnabled, hasGeminiKey {
            let key = geminiAPIKey
            let model = settings.geminiModel
            Task.detached {
                let client = GeminiAPIClient(
                    apiKeyProvider: { key.trimmingCharacters(in: .whitespacesAndNewlines) },
                    model: { model.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
                await client.prewarmConnection()
            }
        }

        let locale = Locale(identifier: settings.localeIdentifier)
        let engine = engine
        startTask = Task { @MainActor [weak self] in
            do {
                try await engine.start(locale: locale)
                guard let self else { return }
                guard self.activeSessionID == sessionID, self.phase != .idle else {
                    return
                }
                AppLog.write(
                    "voice listening started engine=\(engine.engineName) locale=\(locale.identifier) app=\(capturedTarget.appInfo.name) elapsedMs=\(self.elapsedMsSinceHotKey())"
                )
            } catch {
                AppLog.write("voice start failed: \(error.localizedDescription)")
                guard let self else { return }
                if self.activeSessionID == sessionID, self.phase == .listening {
                    self.contextCaptureTask?.cancel()
                    self.presentVoiceError(error)
                    self.finishSession(sessionID)
                }
            }
        }
    }

    private var startTask: Task<Void, Never>?

    private func stopListening() {
        guard case .listening = phase, let sessionID = activeSessionID else {
            return
        }

        phase = .finishing
        setListening(false)
        setStatus("Finishing")
        showPill(.finishing(text: currentTranscriptPreview ?? ""))

        let startTask = startTask
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishSession(sessionID)
            }

            // The key can be released before the analyzer finishes coming up.
            // Wait only a bounded period; cancellation invalidates the engine's
            // own generation so a late prepare cannot start the microphone.
            if let startTask,
               await VoiceLifecycleTimeout.run(timeout: .seconds(3), operation: { await startTask.value }) == nil {
                guard self.activeSessionID == sessionID else { return }
                self.contextCaptureTask?.cancel()
                self.engine.cancel()
                self.presentVoiceError(SpeechDictationError.audioEngineFailed("Voice startup timed out."))
                return
            }

            guard self.activeSessionID == sessionID else { return }
            guard self.engine.isRunning else {
                guard self.activeSessionID == sessionID else { return }
                self.contextCaptureTask?.cancel()
                self.engine.cancel()
                self.presentVoiceError(SpeechDictationError.notRunning)
                return
            }

            enum StopOutcome: Sendable {
                case success(DictationTranscript)
                case failure(String)
            }
            guard let outcome = await VoiceLifecycleTimeout.run(timeout: .seconds(4), operation: {
                do {
                    return StopOutcome.success(try await self.engine.stop())
                } catch {
                    return StopOutcome.failure(error.localizedDescription)
                }
            }) else {
                guard self.activeSessionID == sessionID else { return }
                AppLog.write("voice stop timed out")
                self.contextCaptureTask?.cancel()
                self.engine.cancel()
                self.presentVoiceError(SpeechDictationError.audioEngineFailed("Voice shutdown timed out."))
                return
            }

            switch outcome {
            case .success(let transcript):
                guard self.activeSessionID == sessionID else { return }
                await self.insertTranscript(transcript, sessionID: sessionID)
            case .failure(let message):
                guard self.activeSessionID == sessionID else { return }
                AppLog.write("voice stop failed: \(message)")
                self.contextCaptureTask?.cancel()
                self.presentVoiceError(SpeechDictationError.audioEngineFailed(message))
            }
        }
        finishTask = task
    }

    private func handleTranscriptUpdate(_ transcript: DictationTranscript, sessionID: VoiceSessionID) {
        guard activeSessionID == sessionID, case .listening = phase else {
            return
        }
        let preview = transcript.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentTranscriptPreview = preview.isEmpty ? nil : preview
        showListeningPill()
    }

    // MARK: - Insertion + cleanup

    private func insertTranscript(_ transcript: DictationTranscript, sessionID: VoiceSessionID) async {
        guard activeSessionID == sessionID, let target else {
            return
        }

        let rawText = (transcript.finalizedText + transcript.volatileText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            contextCaptureTask?.cancel()
            setStatus("Ready")
            showPill(.error(message: "聞き取れませんでした"))
            return
        }

        let dictionaryText = dictionary.apply(to: rawText)
        let before = replacer.textBeforeCaret(in: target.inputElement)
        let text = DictationJoiner.prepare(
            dictionaryText,
            precededBy: before,
            localeIdentifier: settings.localeIdentifier
        )
        AppLog.writeTextPreview(
            "voice transcript length=\(text.count) preview=\(logPreview(text))",
            redacted: "voice transcript length=\(text.count) preview=(redacted)"
        )

        let preferClipboardPaste = AppAutomationPolicy.prefersClipboardPaste(for: target.appInfo)
        let record: TextInsertionRecord
        do {
            record = try await replacer.insertAtCaret(
                text,
                in: target.inputElement,
                inputFrame: target.inputFrame,
                preferClipboardPaste: preferClipboardPaste,
                assumeFocused: true
            )
        } catch {
            AppLog.write("voice insertion failed: \(error.localizedDescription)")
            contextCaptureTask?.cancel()
            copyToClipboard(text)
            setStatus("Copied")
            showPill(.error(message: "入力できませんでした。コピー済み"))
            return
        }

        guard activeSessionID == sessionID else {
            return
        }

        AppLog.write("voice insertion method=\(record.method.rawValue) verified=\(record.verified) rangeKnown=\(record.insertedRange != nil)")
        let insertionID = UUID()
        lastInsertion = record
        latestInsertionID = insertionID

        if !record.verified, record.method == .clipboardPaste {
            AppLog.write("voice insertion unverified (electron-style target)")
        }

        let willCleanup = settings.cleanupEnabled && hasGeminiKey
        if willCleanup {
            startKeyboardSwapGuard()
        }

        setStatus("Done")
        if willCleanup {
            showPill(.cleaning(text: text))
        } else {
            showPill(.inserted(text: text))
        }

        guard willCleanup else {
            contextCaptureTask?.cancel()
            return
        }

        scheduleCleanup(record: record, rawText: text, target: target, insertionID: insertionID, sessionID: sessionID)
    }

    private func scheduleCleanup(
        record: TextInsertionRecord,
        rawText: String,
        target: FocusedInputTarget,
        insertionID: UUID,
        sessionID: VoiceSessionID
    ) {
        let settings = settings
        let dictionary = dictionary
        let contextTask = contextCaptureTask
        contextCaptureTask = nil
        let cleaner = makeCleaner()
        cleanupSessionID = sessionID

        let task = Task { @MainActor [weak self] in
            defer { self?.removePendingCleanup(id: insertionID) }
            guard let self else { return }
            guard self.cleanupSessionID == sessionID else { return }

            let contextLines = await contextTask?.value ?? []
            guard !Task.isCancelled, self.cleanupSessionID == sessionID else { return }

            let request = DictationCleanupRequest(
                rawText: rawText,
                appInfo: target.appInfo,
                contextLines: contextLines,
                dictionary: dictionary,
                localeIdentifier: settings.localeIdentifier,
                style: settings.cleanupStyle
            )

            let cleaned: String
            let cleanupStart = Date()
            do {
                cleaned = try await cleaner.cleanup(request, timeout: settings.cleanupTimeoutSeconds)
                AppLog.write("voice cleanup ok elapsedMs=\(Int(Date().timeIntervalSince(cleanupStart) * 1000)) raw=\(rawText.utf16.count) out=\(cleaned.utf16.count)")
            } catch {
                AppLog.write("voice cleanup skipped elapsedMs=\(Int(Date().timeIntervalSince(cleanupStart) * 1000)): \(error.localizedDescription)")
                guard !Task.isCancelled, self.cleanupSessionID == sessionID else { return }
                let decision = self.cleanupDecision(for: insertionID)
                if !decision.isBackground {
                    self.finishWithoutCleanup(rawText: rawText)
                }
                return
            }

            guard !Task.isCancelled, self.cleanupSessionID == sessionID else { return }

            let decision = self.cleanupDecision(for: insertionID)
            let finalText = dictionary.apply(to: cleaned)
            guard finalText != rawText else {
                AppLog.write("voice cleanup: no change")
                if !decision.isBackground {
                    self.finishWithoutCleanup(rawText: rawText)
                }
                return
            }

            guard self.cleanupSessionID == sessionID else { return }
            guard let updated = await self.swapInsertedText(
                record,
                with: finalText,
                logPrefix: "voice cleanup",
                allowKeyboardSwap: decision.allowKeyboardSwap,
                sessionID: sessionID
            ) else {
                if !decision.isBackground {
                    self.stopKeyboardSwapGuard()
                    self.showPill(.inserted(text: "整えはスキップ"))
                }
                return
            }

            guard self.cleanupSessionID == sessionID else { return }

            if decision.updateLastCleanup {
                self.lastInsertion = updated
                self.lastCleanup = (record: updated, rawText: rawText, at: Date())
            }

            if decision.isBackground {
                AppLog.write("voice cleanup applied (background) method=\(updated.method.rawValue)")
                return
            }

            AppLog.writeTextPreview(
                "voice cleanup applied method=\(updated.method.rawValue) preview=\(self.logPreview(finalText))",
                redacted: "voice cleanup applied method=\(updated.method.rawValue) preview=(redacted)"
            )
            self.setStatus("Cleaned")
            self.showPill(.cleaned(text: finalText))
        }
        enqueueCleanup(id: insertionID, task: task)
    }

    private func finishWithoutCleanup(rawText: String) {
        stopKeyboardSwapGuard()
        showPill(.inserted(text: rawText))
    }

    private func swapInsertedText(
        _ record: TextInsertionRecord,
        with newText: String,
        logPrefix: String,
        allowKeyboardSwap: Bool = true,
        sessionID: VoiceSessionID? = nil
    ) async -> TextInsertionRecord? {
        if let sessionID, !isCurrentVoiceSession(sessionID) {
            AppLog.write("\(logPrefix) swap=skipped reason=stale session")
            return nil
        }
        if let updated = await replacer.replaceInsertedText(record, with: newText) {
            if let sessionID, !isCurrentVoiceSession(sessionID) {
                AppLog.write("\(logPrefix) swap=completed after session invalidation")
                return nil
            }
            AppLog.write("\(logPrefix) swap=ax")
            return updated
        }

        guard record.insertedRange == nil else {
            AppLog.write("\(logPrefix) swap=skipped reason=field changed")
            return nil
        }

        guard allowKeyboardSwap else {
            AppLog.write("\(logPrefix) swap=skipped reason=newer session")
            return nil
        }

        guard let swapGuard = keyboardSwapGuard else {
            AppLog.write("\(logPrefix) swap=skipped reason=no guard")
            return nil
        }

        if swapGuard.userTypedSinceInsertion {
            AppLog.write("\(logPrefix) swap=skipped reason=user typed or clicked (\(swapGuard.triggerDescription))")
            return nil
        }

        if let reason = replacer.keyboardSwapSkipReason(record, guard: swapGuard) {
            AppLog.write("\(logPrefix) swap=skipped reason=\(reason.logLabel)")
            return nil
        }

        guard sessionID == nil || isCurrentVoiceSession(sessionID!) else {
            AppLog.write("\(logPrefix) swap=skipped reason=stale session")
            return nil
        }

        if let updated = await replacer.replaceInsertedTextViaKeyboard(record, with: newText, guard: swapGuard) {
            guard sessionID == nil || isCurrentVoiceSession(sessionID!) else {
                AppLog.write("\(logPrefix) swap=completed after session invalidation")
                return nil
            }
            AppLog.write("\(logPrefix) swap=keyboard")
            return updated
        }

        AppLog.write("\(logPrefix) swap=skipped reason=paste failed")
        return nil
    }

    private func isCurrentVoiceSession(_ sessionID: VoiceSessionID) -> Bool {
        activeSessionID == sessionID || cleanupSessionID == sessionID
    }

    private func startKeyboardSwapGuard() {
        stopKeyboardSwapGuard()
        let swapGuard = KeyboardSwapGuard()
        swapGuard.start()
        keyboardSwapGuard = swapGuard
    }

    private func stopKeyboardSwapGuard() {
        keyboardSwapGuard?.stop()
        keyboardSwapGuard = nil
    }

    private func enqueueCleanup(id: UUID, task: Task<Void, Never>) {
        let overflow = VoiceCleanupScheduler.overflowIDs(pendingOrder: pendingCleanupOrder, adding: id)
        for oldID in overflow {
            AppLog.write("voice cleanup cancelled (pending cap)")
            pendingCleanups[oldID]?.cancel()
            pendingCleanups.removeValue(forKey: oldID)
        }
        pendingCleanupOrder.removeAll { overflow.contains($0) || $0 == id }
        pendingCleanupOrder.append(id)
        pendingCleanups[id] = task
    }

    private func removePendingCleanup(id: UUID) {
        pendingCleanups.removeValue(forKey: id)
        pendingCleanupOrder.removeAll { $0 == id }
        if pendingCleanups.isEmpty {
            cleanupSessionID = nil
        }
    }

    private func cleanupDecision(for insertionID: UUID) -> VoiceCleanupScheduler.Decision {
        VoiceCleanupScheduler.decide(
            cleanupInsertionID: insertionID,
            latestInsertionID: latestInsertionID,
            phase: cleanupSessionPhase
        )
    }

    private var cleanupSessionPhase: VoiceCleanupScheduler.Phase {
        switch phase {
        case .idle:
            .idle
        case .listening:
            .listening
        case .finishing:
            .finishing
        }
    }

    private func startContextCapture() {
        let reader = reader
        contextCaptureTask = Task { @MainActor in
            do {
                let composition = try await reader.captureFocusedComposition()
                return ContextWindow.headAndTail(composition.contextLines, limit: 8).map(\.text)
            } catch {
                AppLog.write("voice context capture failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    private func makeCleaner() -> any DictationCleaning {
        let key = geminiAPIKey
        let model = settings.geminiModel
        let client = GeminiAPIClient(
            apiKeyProvider: { key.trimmingCharacters(in: .whitespacesAndNewlines) },
            model: { model.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        return GeminiDictationCleaner(client: client)
    }

    // MARK: - Settings

    func saveSettings() {
        settings.save()
        dictionary.save()
        do {
            try GeminiAPIKeyStore.save(geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            AppLog.write("gemini key save failed: \(error.localizedDescription)")
        }
    }

    func addDictionaryEntry() {
        dictionary.entries.append(DictionaryEntry(id: UUID(), recognized: "", preferred: ""))
    }

    func addVocabulary(_ raw: String) {
        dictionary.addVocabulary(raw)
        dictionary.save()
    }

    func removeDictionaryEntries(ids: Set<UUID>) {
        dictionary.entries.removeAll { ids.contains($0.id) }
        dictionary.save()
    }

    func testGeminiConnection() {
        lastConnectionTestResult = "確認中..."
        let key = geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastConnectionTestResult = "APIキーが未設定です"
            return
        }

        let client = GeminiAPIClient(apiKeyProvider: { key }, model: { model })
        Task { @MainActor [weak self] in
            do {
                let models = try await client.listModels(timeout: 8)
                let hasModel = models.contains(model)
                self?.lastConnectionTestResult = hasModel
                    ? "接続OK（\(model) 利用可）"
                    : "接続OK。ただし \(model) は一覧にありません。利用可: \(models.filter { $0.contains("gemini") }.prefix(6).joined(separator: ", "))"
                AppLog.write("gemini connection test ok models=\(models.count) hasModel=\(hasModel)")
            } catch {
                self?.lastConnectionTestResult = "接続NG: \(error.localizedDescription)"
                AppLog.write("gemini connection test failed: \(error.localizedDescription)")
            }
        }
    }

    func readinessLines(voiceShortcut: String = "⌘ + ⇧ + Space") -> [String] {
        let micStatus: String
        switch MicrophonePermission.status() {
        case .granted:
            micStatus = "OK"
        case .denied:
            micStatus = "未許可"
        default:
            micStatus = "未確認"
        }

        let compactShortcut = voiceShortcut.replacingOccurrences(of: " + ", with: "")
        let engineDetail = engine.engineName == "SpeechAnalyzer"
            ? "SpeechAnalyzer"
            : "SFSpeechRecognizer・macOS 26 未満"
        return [
            "\(isReady ? "OK" : "未準備") 音声入力エンジン (\(engineDetail))",
            "\(isSupported ? "OK" : "非対応") 音声入力 \(compactShortcut)（\(settings.activationMode.readinessLabel)）",
            "\(micStatus) マイク",
            hasGeminiKey ? "OK Gemini整え (\(settings.geminiModel))" : "未設定 Gemini整え（生テキストのみ）"
        ]
    }

    func requestMicrophonePermission() {
        Task { @MainActor [weak self] in
            let granted = await MicrophonePermission.request()
            self?.showHUD(HUDMessage(
                title: granted ? "マイクOK" : "マイクが未許可",
                detail: granted ? nil : "システム設定 > プライバシー > マイク",
                tone: granted ? .success : .warning,
                duration: 3.0
            ))
            if !granted {
                self?.openMicrophoneSettings()
            }
        }
    }

    // MARK: - Helpers

    private func applyActivation(_ action: VoiceActivationStateMachine.Action) {
        switch action {
        case .startListening:
            startListening()
        case .confirm:
            AppLog.write("voice stop requested")
            if phase == .listening {
                stopListening()
            }
        case .none:
            break
        }
    }

    private func resetActivationToIdle() {
        _ = activation.handle(.finished)
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func elapsedMsSinceHotKey() -> Int {
        guard let hotKeyPressedAt else { return 0 }
        return Int(((now() - hotKeyPressedAt) * 1000).rounded())
    }

    private func setListening(_ listening: Bool) {
        isListening = listening
        if phase != .idle {
            let started = escapeMonitor.start { [weak self] in
                Task { @MainActor in
                    self?.cancelActiveSession()
                }
            }
            if !started {
                AppLog.write("voice escape monitor failed to start")
            }
        } else {
            escapeMonitor.stop()
        }
    }

    private func showListeningPill() {
        showPill(.listening(level: currentAudioLevel, text: currentTranscriptPreview ?? ""))
    }

    private func handleAudioLevel(_ level: Float, sessionID: VoiceSessionID) {
        guard activeSessionID == sessionID, case .listening = phase else { return }
        currentAudioLevel = level
        showListeningPill()
    }

    private func showPill(_ state: VoicePillState) {
        voicePill.show(state, inputFrame: target?.inputFrame, hint: sessionHint)
    }

    private func hidePill(animated: Bool) {
        voicePill.hide(animated: animated)
    }

    private var pillHint: String? {
        guard settings.activationMode == .toggleOnly else {
            return nil
        }
        return voiceTriggerDisplayNameProvider().replacingOccurrences(of: " + ", with: "")
    }

    private func handleEngineError(_ error: Error, sessionID: VoiceSessionID) {
        guard activeSessionID == sessionID else { return }
        contextCaptureTask?.cancel()
        if case .listening = phase {
            presentVoiceError(error)
            finishSession(sessionID)
        }
    }

    private func finishSession(_ sessionID: VoiceSessionID) {
        guard activeSessionID == sessionID else { return }
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        startTask = nil
        activeSessionID = nil
        sessionLifecycle.invalidate()
        phase = .idle
        setListening(false)
        resetActivationToIdle()
    }

    private func presentVoiceError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        setStatus("Error")
        showPill(.error(message: message))
        if case SpeechDictationError.microphoneDenied = error {
            openMicrophoneSettings()
        }
    }

    private func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        ]
        for urlString in urls {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showHUD(_ message: HUDMessage) {
        hidePill(animated: false)
        onHUDMessage?(message)
    }

    private func setStatus(_ status: String) {
        onStatusChange?(status)
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

    private func logPreview(_ text: String) -> String {
        let normalized = previewSnippet(text)
        guard normalized.count > 120 else {
            return normalized.isEmpty ? "(empty)" : normalized
        }
        return String(normalized.prefix(120)) + "..."
    }
}
