import AppKit
import ResAICore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem?
    private let hudController = HUDController()
    private var floatingButtonController: FloatingButtonController?
    private var settingsWindowController: SettingsWindowController?
    private var hotKeyManager: GlobalHotKeyManager?
    private var restoreHotKeyManager: GlobalHotKeyManager?
    private var formFillHotKeyManager: GlobalHotKeyManager?
    private var quickMenuHotKeyManager: GlobalHotKeyManager?
    private var voiceHotKeyManager: GlobalHotKeyManager?
    private var hotKeyWatchdog: Timer?
    private var secureInputWasActive = false
    private var hotKeyActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var keyLivenessMonitor: Any?
    private var lastMonitorKeyAt: TimeInterval = 0
    private var appSwitchReregisterTask: Task<Void, Never>?
    private var hotKeyRecoveryCoordinator = HotKeyRecoveryCoordinator()
    private var lastHotKeyRecoveryAt: TimeInterval = 0
    private var lastHotKeyRecoveryDescription = "未実行"
    private var hotKeyRegistrationError: String?
    private var mayRetryMissingRegistration = true
    private var voiceMenuItem: NSMenuItem?
    private var modeMenuItems: [NSMenuItem] = []
    private var floatingButtonMenuItem: NSMenuItem?
    private var menuBarIconMenuItem: NSMenuItem?
    private var rewriteMenuItem: NSMenuItem?
    private var restoreMenuItem: NSMenuItem?
    private var formFillMenuItem: NSMenuItem?
    private var quickMenuItem: NSMenuItem?
    private var shortcutHealthMenuItem: NSMenuItem?
    private var configuredShortcuts: AppShortcuts?
    private var activeHotKeyConfiguration = UUID()
    private var quickMenuInputTarget: FocusedInputTarget?
    private var preferencesObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var appliedFloatingButtonEnabled: Bool?
    private var appliedMenuBarIconEnabled: Bool?
    private var didWarnMenuBarIconHidden = false
    private var showingFloatingButtonForNotch = false

    private var currentHotKeyManagers: [(String, GlobalHotKeyManager?)] {
        [
            ("rewrite", hotKeyManager),
            ("restore", restoreHotKeyManager),
            ("form", formFillHotKeyManager),
            ("menu", quickMenuHotKeyManager),
            ("voice", voiceHotKeyManager)
        ]
    }

    private var areShortcutsReady: Bool {
        guard !GlobalHotKeyManager.isSecureInputActive else {
            return false
        }
        return currentHotKeyManagers.count == 5
            && currentHotKeyManagers.allSatisfy {
                $0.1?.isRegistered == true && $0.1?.isTapEnabled == true
            }
    }

    private func manager(named name: String) -> GlobalHotKeyManager? {
        currentHotKeyManagers.first(where: { $0.0 == name })?.1
    }

    /// Stable, redacted status lines for the Readiness panel and diagnostics.
    private func shortcutDiagnosticsLines() -> [String] {
        let secure = GlobalHotKeyManager.isSecureInputActive
        var lines = [
            "ショートカット: \(areShortcutsReady ? "稼働中" : "未登録 / 要修復")",
            "セキュア入力: \(secure ? "ON（macOS制限中）" : "OFF")",
            "最終復旧: \(lastHotKeyRecoveryDescription)"
        ]
        if let hotKeyRegistrationError {
            lines.append("登録エラー: \(hotKeyRegistrationError)")
        }
        for (name, manager) in currentHotKeyManagers {
            guard let manager else {
                lines.append("\(name): 未登録")
                continue
            }
            let eventAge = manager.secondsSinceLastEvent
            let eventText = eventAge.isFinite ? String(format: "%.1fs前", eventAge) : "未受信"
            lines.append("\(name): \(manager.isTapEnabled ? "有効" : "無効") / 実イベント \(eventText) / 世代 \(manager.registrationGeneration)")
        }
        return lines
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("app launched")
        configureControllerCallbacks()
        configureHotKey()
        configureFloatingButton()
        applyDisplayPreferences()
        configurePreferencesObservation()
        configureScreenParametersObservation()
        controller.startClipboardHistoryMonitoring()
        controller.requestAccessibilityPermissionIfNeeded()
        controller.showStartupStatus()
        controller.voiceInput.warmUp()
        beginHotKeyActivity()
        observeWakeAndUnlock()
        observeAppSwitches()
        startKeyLivenessMonitor()
        startHotKeyWatchdog()
        secureInputWasActive = GlobalHotKeyManager.isSecureInputActive
    }

    /// Global shortcuts can die silently in two ways: macOS switches an event tap off
    /// without delivering the disable event, or another app turns on Secure Keyboard Entry
    /// (password prompt, Terminal, 1Password...) which starves every tap of key events.
    /// Poll for both so the failure is at least visible in the log and, where possible, repaired.
    private func startHotKeyWatchdog() {
        hotKeyWatchdog?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkHotKeyHealth()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        hotKeyWatchdog = timer
    }

    private func checkHotKeyHealth() {
        let secureInput = GlobalHotKeyManager.isSecureInputActive
        if secureInput != secureInputWasActive {
            secureInputWasActive = secureInput
            if secureInput {
                lastHotKeyRecoveryDescription = "セキュア入力中（macOSの制限）"
                AppLog.write("secure keyboard entry ON - global shortcuts are unavailable until it ends; frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                hudController.show(HUDMessage(
                    title: "ショートカットが一時的に使えません",
                    detail: "別のアプリがセキュア入力中です（パスワード欄・ターミナルの「Secure Keyboard Entry」など）。そのアプリを離れると戻ります。",
                    tone: .warning
                ))
            } else {
                AppLog.write("secure keyboard entry OFF - shortcuts available again")
                hudController.hide()
                repairHotKeys(reason: "secure-input-ended", forceRecreate: true)
            }
        }

        guard !secureInput else {
            return
        }

        evaluateHotKeyHealth(reason: "watchdog")
    }

    /// Menu-bar apps get App Nap after idle; that suspends the tap thread and the
    /// watchdog timer, so shortcuts look dead until the user clicks the icon.
    private func beginHotKeyActivity() {
        if let hotKeyActivity {
            ProcessInfo.processInfo.endActivity(hotKeyActivity)
        }
        hotKeyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep global hotkey event taps alive"
        )
    }

    private func observeWakeAndUnlock() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repairHotKeys(reason: "system-wake", forceRecreate: true)
            }
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repairHotKeys(reason: "screen-unlocked", forceRecreate: true)
            }
        }
    }

    private func observeAppSwitches() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleReregisterAfterAppSwitch()
            }
        }
    }

    private func scheduleReregisterAfterAppSwitch() {
        appSwitchReregisterTask?.cancel()
        appSwitchReregisterTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            guard !GlobalHotKeyManager.isSecureInputActive else { return }
            self.evaluateHotKeyHealth(reason: "app-switch")
        }
    }

    private func startKeyLivenessMonitor() {
        if let keyLivenessMonitor {
            NSEvent.removeMonitor(keyLivenessMonitor)
        }
        keyLivenessMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard !SyntheticEventMarker.isSynthetic(event.cgEvent) else { return }
            Task { @MainActor in
                self?.lastMonitorKeyAt = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private func evaluateHotKeyHealth(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let slots = currentHotKeyManagers.map { item in
            let name = item.0
            let manager = item.1
            return HotKeySlotHealth(
                name: name,
                isRegistered: manager?.isRegistered == true,
                isEnabled: manager?.isTapEnabled == true,
                secondsSinceEvent: manager?.secondsSinceLastEvent
            )
        }
        let actions = hotKeyRecoveryCoordinator.actions(
            slots: slots,
            secureInputActive: GlobalHotKeyManager.isSecureInputActive,
            // A missing registration is retried here; Core Graphics remains the
            // source of truth for whether the current permission is sufficient.
            permissionAvailable: true,
            secondsSinceExternalEvent: now - lastMonitorKeyAt
        )
        for action in actions {
            switch action {
            case .registerMissing:
                guard mayRetryMissingRegistration else { continue }
                configureHotKey(reason: "\(reason)-missing")
            case .repairDisabled(let slot):
                guard let manager = manager(named: slot) else { continue }
                if manager.repairTapIfNeeded() {
                    recordHotKeyRecovery("\(slot):disabled", reason: reason)
                }
            case .recreateStale(let slot):
                guard now - lastHotKeyRecoveryAt >= 3,
                      let manager = manager(named: slot)
                else { continue }
                do {
                    try manager.recreateTap()
                    recordHotKeyRecovery("\(slot):stale", reason: reason)
                } catch {
                    hotKeyRegistrationError = error.localizedDescription
                    lastHotKeyRecoveryDescription = "\(slot)復旧失敗: \(error.localizedDescription)"
                    AppLog.write("hotkey recreate failed slot=\(slot) reason=\(reason): \(error.localizedDescription)")
                }
            }
        }
    }

    private func repairHotKeys(reason: String, forceRecreate: Bool = false) {
        guard !GlobalHotKeyManager.isSecureInputActive else {
            lastHotKeyRecoveryDescription = "セキュア入力中のため修復保留"
            AppLog.write("hotkey repair deferred reason=\(reason) secure-input")
            return
        }

        if !areShortcutsReady {
            mayRetryMissingRegistration = true
            configureHotKey(reason: reason)
            return
        }

        if forceRecreate {
            for (name, manager) in currentHotKeyManagers {
                guard let manager else { continue }
                do {
                    try manager.recreateTap()
                    recordHotKeyRecovery("\(name):lifecycle", reason: reason)
                } catch {
                    hotKeyRegistrationError = error.localizedDescription
                    lastHotKeyRecoveryDescription = "\(name)復旧失敗: \(error.localizedDescription)"
                    AppLog.write("hotkey recreate failed slot=\(name) reason=\(reason): \(error.localizedDescription)")
                }
            }
        } else {
            evaluateHotKeyHealth(reason: reason)
        }
    }

    private func recordHotKeyRecovery(_ detail: String, reason: String) {
        lastHotKeyRecoveryAt = ProcessInfo.processInfo.systemUptime
        lastHotKeyRecoveryDescription = "\(detail)（\(reason)）"
        hotKeyRegistrationError = nil
        AppLog.write("global hotkey recovered slot=\(detail) reason=\(reason)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyWatchdog?.invalidate()
        if let hotKeyActivity {
            ProcessInfo.processInfo.endActivity(hotKeyActivity)
            self.hotKeyActivity = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        if let keyLivenessMonitor {
            NSEvent.removeMonitor(keyLivenessMonitor)
        }
        appSwitchReregisterTask?.cancel()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        for (_, manager) in currentHotKeyManagers {
            manager?.unregister()
        }
        controller.shutDown()
        AppLog.flushSync()
    }

    private func configureControllerCallbacks() {
        controller.shortcutDiagnosticsProvider = { [weak self] in
            self?.shortcutDiagnosticsLines() ?? ["ショートカット: 未確認"]
        }
        controller.shortcutsAreReady = { [weak self] in
            self?.areShortcutsReady ?? false
        }
        controller.onAccessibilityPermissionGranted = { [weak self] in
            self?.mayRetryMissingRegistration = true
            self?.configureHotKey(reason: "accessibility-permission-granted")
        }
        controller.onStatusChange = { [weak self] status in
            self?.statusItem?.button?.toolTip = status == "ResponseAi" ? "ResponseAi" : status
        }
        controller.onHUDMessage = { [weak hudController] message in
            hudController?.show(message)
        }
        controller.onHideHUD = { [weak hudController] in
            hudController?.hide()
        }
        controller.onModeChange = { [weak self] _ in
            self?.updateModeMenuState()
        }
        controller.onShortcutsChange = { [weak self] _ in
            self?.configureHotKey()
            self?.updateShortcutMenuItems()
        }
    }

    private func configurePreferencesObservation() {
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyDisplayPreferences()
            }
        }
    }

    private func configureScreenParametersObservation() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkStatusItemVisibility()
            }
        }
    }

    private func refreshStatusItem() {
        guard isMenuBarIconEnabled else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
                menuBarIconMenuItem = nil
                AppLog.write("menu bar icon hidden")
            }
            clearNotchHiddenStateIfNeeded()
            return
        }

        if let item = statusItem {
            configureStatusButton(item.button)
            item.menu = buildMenu()
            scheduleStatusItemVisibilityCheck()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusButton(item.button)
        item.menu = buildMenu()
        statusItem = item
        AppLog.write("menu bar icon shown")
        scheduleStatusItemVisibilityCheck()
    }

    private func configureStatusButton(_ button: NSStatusBarButton?) {
        guard let button else {
            return
        }

        if let image = menuBarTemplateImage() {
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
        } else {
            button.title = "R"
        }

        button.toolTip = "ResponseAi"
    }

    private func menuBarTemplateImage() -> NSImage? {
        if let image = bundledMenuBarTemplateImage() {
            return image
        }

        guard let image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "ResponseAi") else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func bundledMenuBarTemplateImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for name in ["ResponseAiTemplate", "ResponseAiTemplate@2x", "ResponseAiTemplate@3x"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else {
                continue
            }
            representation.size = NSSize(width: 18, height: 18)
            image.addRepresentation(representation)
        }

        guard !image.representations.isEmpty else {
            return nil
        }

        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let health = NSMenuItem(title: "ショートカット状態を確認中", action: nil, keyEquivalent: "")
        health.isEnabled = false
        shortcutHealthMenuItem = health
        menu.addItem(health)
        menu.addItem(.separator())
        let voiceItem = NSMenuItem(
            title: voiceMenuTitle(for: controller.shortcuts.voiceTrigger),
            action: #selector(toggleVoiceInput),
            keyEquivalent: ""
        )
        applyVoiceMenuShortcut(to: voiceItem)
        voiceMenuItem = voiceItem
        menu.addItem(voiceItem)

        let rewriteItem = NSMenuItem(
            title: "返信を整える",
            action: #selector(rewriteFocusedDraft),
            keyEquivalent: controller.shortcuts.rewrite.keyEquivalent
        )
        rewriteItem.keyEquivalentModifierMask = [.command, .shift]
        rewriteMenuItem = rewriteItem
        menu.addItem(rewriteItem)

        let restoreItem = NSMenuItem(
            title: "直前の下書きに戻す",
            action: #selector(restoreLastDraft),
            keyEquivalent: controller.shortcuts.restore.keyEquivalent
        )
        restoreItem.keyEquivalentModifierMask = [.command, .shift]
        restoreMenuItem = restoreItem
        menu.addItem(restoreItem)

        let formFillItem = NSMenuItem(
            title: "プロフィールでフォーム入力",
            action: #selector(fillFormFromProfile),
            keyEquivalent: controller.shortcuts.formFill.keyEquivalent
        )
        formFillItem.keyEquivalentModifierMask = [.command, .shift]
        formFillMenuItem = formFillItem
        menu.addItem(formFillItem)

        let quickItem = NSMenuItem(
            title: "クイックメニュー",
            action: #selector(showQuickActionMenu),
            keyEquivalent: controller.shortcuts.quickMenu.keyEquivalent
        )
        quickItem.keyEquivalentModifierMask = [.command, .shift]
        quickMenuItem = quickItem
        menu.addItem(quickItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(modeMenuItem())
        let floatingItem = NSMenuItem(
            title: "フローティングボタンを表示",
            action: #selector(toggleFloatingButton),
            keyEquivalent: ""
        )
        floatingButtonMenuItem = floatingItem
        menu.addItem(floatingItem)
        let menuBarIconItem = NSMenuItem(
            title: "メニューバーアイコンを表示",
            action: #selector(toggleMenuBarIcon),
            keyEquivalent: ""
        )
        menuBarIconMenuItem = menuBarIconItem
        menu.addItem(menuBarIconItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "設定",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(NSMenuItem(
            title: "アクセシビリティ権限を開く",
            action: #selector(requestAccessibilityPermission),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "ショートカットを修復",
            action: #selector(repairHotKeysFromMenu),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "画面収録権限を開く",
            action: #selector(requestScreenRecordingPermission),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "準備状況を確認",
            action: #selector(runReadinessCheck),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "再起動",
            action: #selector(restart),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "ResponseAiを終了",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        for item in menu.items {
            item.target = self
        }

        updateModeMenuState()
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        shortcutHealthMenuItem?.title = GlobalHotKeyManager.isSecureInputActive
            ? "セキュア入力中 — ショートカット停止"
            : (areShortcutsReady ? "ショートカット正常" : "ショートカット要修復")
    }

    private func modeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "文体", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        modeMenuItems = RewriteMode.allCases.map { mode in
            let menuItem = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectMode),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.representedObject = mode.rawValue
            submenu.addItem(menuItem)
            return menuItem
        }
        item.submenu = submenu
        return item
    }

    private func configureHotKey(reason: String = "configuration") {
        let shortcuts = controller.shortcuts.sanitized()
        if reason == "configuration", configuredShortcuts == shortcuts,
           currentHotKeyManagers.allSatisfy({ $0.1?.isRegistered == true }) {
            evaluateHotKeyHealth(reason: "settings-unchanged")
            return
        }
        let configuration = UUID()
        let rewriteManager = GlobalHotKeyManager { [weak self] in
            Task { @MainActor in
                guard self?.activeHotKeyConfiguration == configuration else { return }
                AppLog.write("rewrite hotkey received")
                self?.rewriteFocusedDraft()
            }
        }
        let restoreManager = GlobalHotKeyManager { [weak self] in
            Task { @MainActor in
                guard self?.activeHotKeyConfiguration == configuration else { return }
                AppLog.write("restore hotkey received")
                self?.restoreLastDraft()
            }
        }
        let formFillManager = GlobalHotKeyManager { [weak self] in
            Task { @MainActor in
                guard self?.activeHotKeyConfiguration == configuration else { return }
                AppLog.write("form fill hotkey received")
                self?.fillFormFromProfile()
            }
        }
        let quickMenuManager = GlobalHotKeyManager { [weak self] in
            Task { @MainActor in
                guard self?.activeHotKeyConfiguration == configuration else { return }
                AppLog.write("quick menu hotkey received")
                self?.showQuickActionMenu()
            }
        }
        let voiceManager = GlobalHotKeyManager(
            callback: { [weak self] in
                Task { @MainActor in
                    guard self?.activeHotKeyConfiguration == configuration else { return }
                    AppLog.write("voice hotkey received")
                    self?.controller.voiceInput.hotKeyPressed()
                }
            },
            onRelease: { [weak self] in
                Task { @MainActor in
                    guard self?.activeHotKeyConfiguration == configuration else { return }
                    AppLog.write("voice hotkey released")
                    self?.controller.voiceInput.hotKeyReleased()
                }
            }
        )

        let candidates: [(String, GlobalHotKeyManager)] = [
            ("rewrite", rewriteManager), ("restore", restoreManager), ("form", formFillManager),
            ("menu", quickMenuManager), ("voice", voiceManager)
        ]
        for (name, manager) in candidates {
            manager.onTapDisabled = { [weak self] disableReason in
                Task { @MainActor in
                    AppLog.write("event tap disabled slot=\(name) reason=\(disableReason.rawValue)")
                    self?.lastHotKeyRecoveryDescription = "\(name)無効化通知: \(disableReason.rawValue)"
                }
            }
            manager.onTapReenabled = { [weak self] in
                Task { @MainActor in
                    AppLog.write("event tap re-enabled slot=\(name) after actual disable")
                    self?.lastHotKeyRecoveryDescription = "\(name)再有効化（イベントタップ通知）"
                }
            }
        }

        do {
            try rewriteManager.register(shortcuts.rewrite, id: 1)
            try restoreManager.register(shortcuts.restore, id: 2)
            try formFillManager.register(shortcuts.formFill, id: 3)
            try quickMenuManager.register(shortcuts.quickMenu, id: 4)
            switch shortcuts.voiceTrigger {
            case .commandShift(let key):
                try voiceManager.register(HotKeyShortcut(key: key), id: 5)
            case .fnCommand:
                try voiceManager.register(modifierChord: [.maskSecondaryFn, .maskCommand], id: 5)
            case .commandSpace:
                try voiceManager.register(keyCode: VoiceTrigger.commandSpaceKeyCode, modifiers: VoiceTrigger.commandSpaceModifiers, id: 5)
            }

            // Stage all five taps before touching the active set. If any one tap
            // fails, the candidate set is fully released and the previous set stays
            // live. This prevents both self-retain leaks and partial replacement.
            if controller.voiceInput.isBusy { controller.voiceInput.cancelActiveSession() }
            for (_, oldManager) in currentHotKeyManagers {
                oldManager?.unregister()
            }
            hotKeyManager = rewriteManager
            restoreHotKeyManager = restoreManager
            formFillHotKeyManager = formFillManager
            quickMenuHotKeyManager = quickMenuManager
            voiceHotKeyManager = voiceManager
            activeHotKeyConfiguration = configuration
            configuredShortcuts = shortcuts
            hotKeyRegistrationError = nil
            lastHotKeyRecoveryDescription = "登録完了（\(reason)）"
            mayRetryMissingRegistration = true
            AppLog.write("global hotkeys registered rewrite=\(shortcuts.rewrite.displayName) restore=\(shortcuts.restore.displayName) form=\(shortcuts.formFill.displayName) menu=\(shortcuts.quickMenu.displayName) voice=\(shortcuts.voiceTrigger.displayName)")
        } catch {
            for (_, candidate) in candidates {
                candidate.unregister()
            }
            hotKeyRegistrationError = error.localizedDescription
            lastHotKeyRecoveryDescription = "登録失敗（\(reason)）"
            mayRetryMissingRegistration = false
            AppLog.write("global hotkey registration failed reason=\(reason): \(error.localizedDescription)")
            if reason != "watchdog-missing" && reason != "app-switch-missing" {
                controller.presentError(error, showAlert: true)
            }
        }
    }

    private func configureFloatingButton() {
        let floating = FloatingButtonController(
            onRewrite: { [weak self] in
                AppLog.write("floating rewrite clicked")
                self?.rewriteFocusedDraft()
            },
            onRestore: { [weak self] in
                AppLog.write("floating restore clicked")
                self?.restoreLastDraft()
            },
            onSettings: { [weak self] in
                AppLog.write("floating settings clicked")
                self?.openSettings()
            }
        )
        floatingButtonController = floating
    }

    @objc private func rewriteFocusedDraft() {
        AppLog.write("rewrite requested")
        controller.rewriteFocusedDraft()
    }

    @objc private func toggleVoiceInput() {
        AppLog.write("voice input requested from menu")
        controller.voiceInput.hotKeyPressed()
    }

    @objc private func restoreLastDraft() {
        AppLog.write("restore requested")
        controller.restoreLastDraft()
    }

    @objc private func fillFormFromProfile() {
        AppLog.write("form fill requested")
        controller.fillFormFromProfile()
    }

    @objc private func showQuickActionMenu() {
        quickMenuInputTarget = controller.focusedInputTargetForUI()
        let menu = NSMenu(title: "ResponseAi")
        menu.autoenablesItems = false

        addClipboardHistorySection(to: menu)
        menu.addItem(.separator())
        addQuickActionTab(to: menu)
        menu.addItem(.separator())
        addSettingsItem(to: menu)
        menu.addItem(.separator())
        addClearClipboardHistoryItem(to: menu)

        _ = menu.popUp(positioning: nil, at: quickActionMenuPoint(), in: nil)
    }

    private func addQuickActionTab(to menu: NSMenu) {
        let tabItem = NSMenuItem(title: "AIアクション", action: nil, keyEquivalent: "")
        tabItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AIアクション")
        let submenu = NSMenu(title: "AIアクション")

        for action in QuickAction.allCases {
            if action.startsNewGroup {
                submenu.addItem(.separator())
            }

            let item = NSMenuItem(
                title: action.title,
                action: #selector(runQuickAction),
                keyEquivalent: ""
            )
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = action.rawValue
            if let symbolName = action.symbolName {
                item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: action.title)
            }
            submenu.addItem(item)
        }

        tabItem.submenu = submenu
        menu.addItem(tabItem)
    }

    private func addClipboardHistorySection(to menu: NSMenu) {
        addDisabledHeader("クリップボード履歴", to: menu)

        guard controller.clipboardHistory.isEnabled else {
            addDisabledItem("履歴はオフです", to: menu)
            return
        }

        let items = controller.clipboardHistory.items
        guard !items.isEmpty else {
            addDisabledItem("履歴なし", to: menu)
            return
        }

        for pageIndex in 0..<historyPageCount(for: items.count) {
            let startIndex = pageIndex * historyPageSize
            let endIndex = min(startIndex + historyPageSize, items.count)
            let pageItems = Array(items[startIndex..<endIndex])
            let tabTitle = clipboardHistoryTabTitle(
                pageIndex: pageIndex,
                startIndex: startIndex,
                endIndex: endIndex
            )
            let tabItem = NSMenuItem(title: tabTitle, action: nil, keyEquivalent: "")
            tabItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: tabTitle)
            let submenu = NSMenu(title: tabTitle)

            for (itemIndex, item) in pageItems.enumerated() {
                let key = historyKeyEquivalents[itemIndex]
                let menuItem = NSMenuItem(
                    title: "\(key)  \(item.previewTitle)",
                    action: #selector(pasteClipboardHistoryItem),
                    keyEquivalent: key
                )
                menuItem.keyEquivalentModifierMask = []
                menuItem.target = self
                menuItem.representedObject = item.id.uuidString
                menuItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "クリップボード履歴")
                submenu.addItem(menuItem)
            }

            tabItem.submenu = submenu
            menu.addItem(tabItem)
        }

    }

    private func addClearClipboardHistoryItem(to menu: NSMenu) {
        let clearItem = NSMenuItem(
            title: "履歴を消去",
            action: #selector(clearClipboardHistory),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "履歴を消去")
        menu.addItem(clearItem)
    }

    private func addSettingsItem(to menu: NSMenu) {
        let settingsItem = NSMenuItem(
            title: "設定",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "設定")
        menu.addItem(settingsItem)
    }

    private func addDisabledHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func pasteClipboardHistoryItem(_ sender: NSMenuItem) {
        guard
            let idString = sender.representedObject as? String,
            let id = UUID(uuidString: idString)
        else {
            return
        }

        AppLog.write("clipboard history selected")
        controller.pasteClipboardHistoryItem(id: id, target: quickMenuInputTarget)
    }

    @objc private func clearClipboardHistory() {
        AppLog.write("clipboard history cleared")
        controller.clearClipboardHistory()
    }

    @objc private func runQuickAction(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let action = QuickAction(rawValue: rawValue)
        else {
            return
        }

        AppLog.write("quick action selected \(action.rawValue)")
        switch action {
        case .balanced:
            controller.rewriteFocusedDraft(mode: .balanced)
        case .polite:
            controller.rewriteFocusedDraft(mode: .polite)
        case .concise:
            controller.rewriteFocusedDraft(mode: .concise)
        case .warm:
            controller.rewriteFocusedDraft(mode: .warm)
        case .decline:
            controller.rewriteFocusedDraft(mode: .decline)
        case .scheduling:
            controller.rewriteFocusedDraft(mode: .scheduling)
        case .english:
            controller.rewriteFocusedDraft(language: .english)
        case .japanese:
            controller.rewriteFocusedDraft(language: .japanese)
        case .formFill:
            controller.fillFormFromProfile()
        case .restore:
            controller.restoreLastDraft()
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let mode = RewriteMode(rawValue: rawValue)
        else {
            return
        }
        controller.setMode(mode)
        updateModeMenuState()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(controller: controller)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func requestAccessibilityPermission() {
        controller.requestAccessibilityPermission(showAlert: true)
    }

    @objc private func repairHotKeysFromMenu() {
        AppLog.write("manual hotkey repair requested")
        repairHotKeys(reason: "manual")
    }

    @objc private func requestScreenRecordingPermission() {
        controller.requestScreenRecordingPermission()
    }

    @objc private func runReadinessCheck() {
        controller.runReadinessCheck()
    }

    @objc private func toggleFloatingButton() {
        let nextValue = !isFloatingButtonEnabled
        UserDefaults.standard.set(nextValue, forKey: "ui.showFloatingButton")
        applyDisplayPreferences()
    }

    @objc private func toggleMenuBarIcon() {
        let nextValue = !isMenuBarIconEnabled
        UserDefaults.standard.set(nextValue, forKey: "ui.showMenuBarIcon")
        DispatchQueue.main.async { [weak self] in
            self?.applyDisplayPreferences()
        }
    }

    private func applyDisplayPreferences() {
        let floatingEnabled = isFloatingButtonEnabled
        if appliedFloatingButtonEnabled != floatingEnabled {
            if floatingEnabled {
                floatingButtonController?.show()
                AppLog.write("floating button shown")
            } else if !showingFloatingButtonForNotch {
                floatingButtonController?.hide()
                AppLog.write("floating button hidden by preference")
            }
            appliedFloatingButtonEnabled = floatingEnabled
        }

        let menuBarEnabled = isMenuBarIconEnabled
        if appliedMenuBarIconEnabled != menuBarEnabled || (menuBarEnabled && statusItem == nil) || (!menuBarEnabled && statusItem != nil) {
            refreshStatusItem()
            appliedMenuBarIconEnabled = menuBarEnabled
        }
        updateModeMenuState()
    }

    @objc private func restart() {
        AppLog.write("app restart requested")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    AppLog.write("app restart launch failed: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateModeMenuState() {
        for item in modeMenuItems {
            let rawValue = item.representedObject as? String
            item.state = rawValue == controller.mode.rawValue ? .on : .off
        }
        floatingButtonMenuItem?.state = isFloatingButtonEnabled ? .on : .off
        menuBarIconMenuItem?.state = isMenuBarIconEnabled ? .on : .off
    }

    private func updateShortcutMenuItems() {
        rewriteMenuItem?.keyEquivalent = controller.shortcuts.rewrite.keyEquivalent
        restoreMenuItem?.keyEquivalent = controller.shortcuts.restore.keyEquivalent
        formFillMenuItem?.keyEquivalent = controller.shortcuts.formFill.keyEquivalent
        quickMenuItem?.keyEquivalent = controller.shortcuts.quickMenu.keyEquivalent
        for item in [rewriteMenuItem, restoreMenuItem, formFillMenuItem, quickMenuItem].compactMap({ $0 }) {
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        if let voiceMenuItem {
            applyVoiceMenuShortcut(to: voiceMenuItem)
        }
    }

    private func applyVoiceMenuShortcut(to item: NSMenuItem) {
        let trigger = controller.shortcuts.voiceTrigger
        item.title = voiceMenuTitle(for: trigger)
        switch trigger {
        case .commandShift(let key):
            item.keyEquivalent = key.keyEquivalent
            item.keyEquivalentModifierMask = [.command, .shift]
        case .fnCommand:
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        case .commandSpace:
            item.keyEquivalent = " "
            item.keyEquivalentModifierMask = [.command]
        }
    }

    private func voiceMenuTitle(for trigger: VoiceTrigger) -> String {
        switch trigger {
        case .commandShift:
            "音声入力 開始 / 確定"
        case .fnCommand, .commandSpace:
            "音声入力 開始 / 確定 \(trigger.displayName)"
        }
    }

    private func quickActionMenuPoint() -> NSPoint {
        let menuWidth: CGFloat = 260
        if
            let inputFrame = quickMenuInputTarget?.inputFrame,
            let screen = screen(for: inputFrame)
        {
            let visible = screen.visibleFrame
            let x = clamp(inputFrame.minX + 8, min: visible.minX + 12, max: visible.maxX - menuWidth)
            let y = clamp(screen.frame.maxY - inputFrame.minY + 8, min: visible.minY + 72, max: visible.maxY - 12)
            return NSPoint(x: x, y: y)
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else {
            return mouse
        }

        let visible = screen.visibleFrame
        return NSPoint(
            x: clamp(mouse.x, min: visible.minX + 12, max: visible.maxX - menuWidth),
            y: clamp(mouse.y, min: visible.minY + 72, max: visible.maxY - 12)
        )
    }

    private func screen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        } ?? NSScreen.main
    }

    private func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private var isFloatingButtonEnabled: Bool {
        UserDefaults.standard.object(forKey: "ui.showFloatingButton") as? Bool ?? false
    }

    private var isMenuBarIconEnabled: Bool {
        UserDefaults.standard.object(forKey: "ui.showMenuBarIcon") as? Bool ?? true
    }

    private func scheduleStatusItemVisibilityCheck() {
        DispatchQueue.main.async { [weak self] in
            self?.checkStatusItemVisibility(treatMissingWindowAsHidden: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.checkStatusItemVisibility(treatMissingWindowAsHidden: true)
        }
    }

    private func checkStatusItemVisibility(treatMissingWindowAsHidden: Bool = true) {
        guard isMenuBarIconEnabled, statusItem != nil else {
            clearNotchHiddenStateIfNeeded()
            return
        }

        if statusItem?.button?.window == nil, !treatMissingWindowAsHidden {
            return
        }

        let hidden = isStatusItemHiddenByNotchOrOverflow()
        if hidden {
            applyStatusItemHiddenByNotch()
        } else {
            applyStatusItemBecameVisible()
        }
    }

    private func isStatusItemHiddenByNotchOrOverflow() -> Bool {
        let window = statusItem?.button?.window
        let screen = window?.screen ?? NSScreen.main
        let gap: Range<CGFloat>? = screen.flatMap { screen in
            MenuBarIconVisibility.notchGapXRange(
                leftArea: screen.auxiliaryTopLeftArea,
                rightArea: screen.auxiliaryTopRightArea
            )
        }
        return MenuBarIconVisibility.isHidden(
            windowExists: window != nil,
            occlusionContainsVisible: window?.occlusionState.contains(.visible) ?? false,
            windowFrame: window?.frame ?? .zero,
            notchGapXRange: gap
        )
    }

    private func applyStatusItemHiddenByNotch() {
        if !controller.menuBarIconHiddenByNotch {
            AppLog.write("menu bar icon hidden (notch/overflow)")
        }
        controller.menuBarIconHiddenByNotch = true

        if !didWarnMenuBarIconHidden {
            didWarnMenuBarIconHidden = true
            controller.onHUDMessage?(HUDMessage(
                title: "メニューバーのアイコンがノッチに隠れています",
                detail: "⌘⇧V でメニュー / フローティングボタン表示中",
                tone: .warning,
                duration: 4.0
            ))
        }

        showingFloatingButtonForNotch = true
        floatingButtonController?.show()
    }

    private func applyStatusItemBecameVisible() {
        let wasHidden = controller.menuBarIconHiddenByNotch
        controller.menuBarIconHiddenByNotch = false
        guard showingFloatingButtonForNotch else {
            return
        }
        showingFloatingButtonForNotch = false
        if wasHidden {
            AppLog.write("menu bar icon visible")
        }
        if !isFloatingButtonEnabled {
            floatingButtonController?.hide()
            AppLog.write("floating button hidden after menu bar icon became visible")
        }
    }

    private func clearNotchHiddenStateIfNeeded() {
        controller.menuBarIconHiddenByNotch = false
        guard showingFloatingButtonForNotch else {
            return
        }
        showingFloatingButtonForNotch = false
        if !isFloatingButtonEnabled {
            floatingButtonController?.hide()
        }
    }

    private var historyKeyEquivalents: [String] {
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    }

    private var historyPageSize: Int {
        historyKeyEquivalents.count
    }

    private func historyPageCount(for itemCount: Int) -> Int {
        (itemCount + historyPageSize - 1) / historyPageSize
    }

    private func clipboardHistoryTabTitle(pageIndex: Int, startIndex: Int, endIndex: Int) -> String {
        let tabNumber = pageIndex + 1
        let range = "\(startIndex + 1)-\(endIndex)"
        if pageIndex == 0 {
            return "\(tabNumber) 最新 \(range)"
        }
        return "\(tabNumber) 履歴 \(range)"
    }
}

private enum QuickAction: String, CaseIterable {
    case balanced
    case polite
    case concise
    case warm
    case decline
    case scheduling
    case english
    case japanese
    case formFill
    case restore

    var title: String {
        switch self {
        case .balanced:
            "自然に整える"
        case .polite:
            "丁寧に整える"
        case .concise:
            "短くする"
        case .warm:
            "やわらかくする"
        case .decline:
            "断り文にする"
        case .scheduling:
            "日程調整にする"
        case .english:
            "英語で返す"
        case .japanese:
            "日本語で返す"
        case .formFill:
            "プロフィールでフォーム入力"
        case .restore:
            "直前の下書きに戻す"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .balanced: "1"
        case .polite: "2"
        case .concise: "3"
        case .warm: "4"
        case .decline: "5"
        case .scheduling: "6"
        case .english: "7"
        case .japanese: "8"
        case .formFill: "9"
        case .restore: "0"
        }
    }

    var symbolName: String? {
        switch self {
        case .balanced:
            "sparkles"
        case .polite:
            "briefcase"
        case .concise:
            "text.alignleft"
        case .warm:
            "hand.wave"
        case .decline:
            "arrow.uturn.left"
        case .scheduling:
            "calendar"
        case .english, .japanese:
            "globe"
        case .formFill:
            "square.and.pencil"
        case .restore:
            "arrow.uturn.backward"
        }
    }

    var startsNewGroup: Bool {
        switch self {
        case .formFill:
            true
        default:
            false
        }
    }
}
