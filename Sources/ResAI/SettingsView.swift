import ResAICore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var clipboardHistory: ClipboardHistoryStore
    @ObservedObject private var voiceInput: VoiceInputController
    @AppStorage("ui.showFloatingButton") private var showFloatingButton = false
    @AppStorage("ui.showMenuBarIcon") private var showMenuBarIcon = true
    @State private var showsAdvanced = false
    @State private var showsGeminiKey = false
    @State private var bulkVocabulary = ""

    init(controller: AppController) {
        self._controller = ObservedObject(wrappedValue: controller)
        self._clipboardHistory = ObservedObject(wrappedValue: controller.clipboardHistory)
        self._voiceInput = ObservedObject(wrappedValue: controller.voiceInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    voiceSection

                    Divider()

                    rewriteSection

                    Divider()

                    displaySection

                    Divider()

                    shortcutsSection

                    Divider()

                    clipboardSection

                    Divider()

                    profileSection

                    Divider()

                    privacySection

                    Divider()

                    DisclosureGroup("詳細接続設定", isExpanded: $showsAdvanced) {
                        connectionSection
                            .padding(.top, 10)
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .padding(18)
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: controller.saveConfig) {
                    Label("保存", systemImage: "checkmark")
                }
                    .keyboardShortcut(.defaultAction)
                Button {
                    controller.requestAccessibilityPermission()
                } label: {
                    Label("アクセシビリティ", systemImage: "hand.raised")
                }
                Button {
                    controller.requestScreenRecordingPermission()
                } label: {
                    Label("画面収録", systemImage: "rectangle.dashed")
                }
                Button {
                    controller.runReadinessCheck()
                } label: {
                    Label("確認", systemImage: "checklist")
                }
                Spacer()
                Text(controller.lastStatusDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .onChange(of: controller.mode) { _, newValue in
            controller.setMode(newValue)
        }
        .onChange(of: controller.rewriteLanguage) { _, newValue in
            controller.setRewriteLanguage(newValue)
        }
        .onChange(of: controller.screenTextContextEnabled) { _, _ in
            controller.savePrivacySettings()
        }
        .onChange(of: controller.diagnosticTextPreviewLoggingEnabled) { _, _ in
            controller.savePrivacySettings()
        }
        .onChange(of: controller.userProfile) { _, _ in
            controller.saveUserProfile()
        }
        .onChange(of: controller.userProfileEnabled) { _, _ in
            controller.saveUserProfile()
        }
        .onChange(of: controller.shortcuts) { _, _ in
            controller.saveShortcuts(showHUD: false)
        }
        .onChange(of: voiceInput.settings) { _, _ in
            voiceInput.saveSettings()
        }
        .onChange(of: voiceInput.dictionary) { _, _ in
            voiceInput.saveSettings()
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音声入力")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(voiceHelpText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("起動", selection: $voiceInput.settings.activationMode) {
                ForEach(VoiceActivationMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Gemini で整える", isOn: $voiceInput.settings.cleanupEnabled)
                .help("入力は先に生テキストで行い、整った文が返ってきたら自分が入れた部分だけ差し替えます。オフなら端末内だけで完結します。")

            if voiceInput.settings.cleanupEnabled {
                Picker("整え方", selection: $voiceInput.settings.cleanupStyle) {
                    ForEach(DictationCleanupStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text(voiceInput.settings.cleanupStyle.help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Gemini APIキー")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if showsGeminiKey {
                            TextField("AIza...", text: $voiceInput.geminiAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("AIza...", text: $voiceInput.geminiAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            showsGeminiKey.toggle()
                        } label: {
                            Image(systemName: showsGeminiKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showsGeminiKey ? "隠す" : "表示")
                    }
                }
                GridRow {
                    Text("モデル")
                        .foregroundStyle(.secondary)
                    TextField("gemini-3.8-flash", text: $voiceInput.settings.geminiModel)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("言語")
                        .foregroundStyle(.secondary)
                    Picker("言語", selection: $voiceInput.settings.localeIdentifier) {
                        Text("日本語").tag("ja_JP")
                        Text("English (US)").tag("en_US")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }
            }

            Toggle("入力欄の上の文脈を整えの参考に送る", isOn: $voiceInput.settings.includeScreenContext)
                .help("同音異義語の判断のために、入力欄の上に見えている数行をテキストで送ります。音声は送りません。")

            HStack(spacing: 8) {
                Button {
                    voiceInput.saveSettings()
                    voiceInput.testGeminiConnection()
                } label: {
                    Label("接続テスト", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    voiceInput.requestMicrophonePermission()
                } label: {
                    Label("マイク権限", systemImage: "mic")
                }
                if let result = voiceInput.lastConnectionTestResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.bordered)

            dictionaryEditor
        }
    }

    private var voiceHelpText: String {
        let shortcut = controller.shortcuts.voiceTrigger.displayName
        switch voiceInput.settings.activationMode {
        case .holdOrTap:
            return "\(shortcut) を長押しすると聞き取り、離すと確定。短いタップはトグル（もう一度で確定）。Esc で中止。"
        case .toggleOnly:
            return "\(shortcut) を1回押すと聞き取り開始、もう一度押すと確定。Esc で中止。"
        }
    }

    private var dictionaryEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ユーザー辞書")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(voiceInput.dictionary.entries.count) 件")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14))
                    .clipShape(Capsule())
                Spacer()
                Button {
                    voiceInput.addDictionaryEntry()
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Text("左を空にすると語彙として登録（誤認識をこの表記に寄せる）。左右を入れると文字列置換。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($voiceInput.dictionary.entries) { $entry in
                HStack(spacing: 8) {
                    TextField("（任意）誤認識の表記", text: $entry.recognized)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("正しい表記", text: $entry.preferred)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        voiceInput.removeDictionaryEntries(ids: [entry.id])
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 8) {
                TextField("Funnel Ai, Cursor, 商談化率 …", text: $bulkVocabulary)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitBulkVocabulary)
                Button("まとめて追加") {
                    submitBulkVocabulary()
                }
                .disabled(bulkVocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitBulkVocabulary() {
        let raw = bulkVocabulary
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        voiceInput.addVocabulary(raw)
        bulkVocabulary = ""
    }

    private var rewriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("返信")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("文体", selection: $controller.mode) {
                ForEach(RewriteMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("返信言語", selection: $controller.rewriteLanguage) {
                ForEach(RewriteLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("表示")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("フローティングボタンを表示", isOn: $showFloatingButton)
                .help("画面右側の半透明ボタンを表示します。")

            Toggle("メニューバーアイコンを表示", isOn: $showMenuBarIcon)
                .help("画面右上のResponseAiアイコンを表示します。")
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("プライバシー")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("ブラウザで見えている文脈を読み取る", isOn: $controller.screenTextContextEnabled)
                .help("ブラウザのアクセシビリティ文脈が弱いときだけ、返信欄の上に見えているテキストを読み取ります。")

            Toggle("デバッグ用にテキストプレビューをログ保存", isOn: $controller.diagnosticTextPreviewLoggingEnabled)
                .help("通常はオフです。オンにすると、短い下書き/文脈プレビューをローカル診断ログに保存します。")
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ショートカット")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("音声入力")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("音声トリガー", selection: voiceTriggerKind) {
                            Text("⌘ + ⇧ + キー").tag(VoiceTriggerKind.commandShift)
                            Text("fn + ⌘").tag(VoiceTriggerKind.fnCommand)
                            Text("⌘ + Space").tag(VoiceTriggerKind.commandSpace)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)

                        if case .commandShift = controller.shortcuts.voiceTrigger {
                            shortcutPicker(selection: voiceKeyBinding)
                        }

                        if case .fnCommand = controller.shortcuts.voiceTrigger {
                            Text("システム設定 > キーボード >「🌐 キーを押して」を「何もしない」にしてください（音声入力/絵文字が開くのを防ぐため）")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if case .commandSpace = controller.shortcuts.voiceTrigger {
                            Text("Spotlight と競合します。システム設定 > キーボード > キーボードショートカット > Spotlight で「Spotlight 検索を表示」をオフにするか別のキーに変えてください。入力ソース切替を ⌘Space にしている場合も同様です。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    Text("返信")
                        .foregroundStyle(.secondary)
                    shortcutPicker(selection: $controller.shortcuts.rewrite.key)
                }
                GridRow {
                    Text("復元")
                        .foregroundStyle(.secondary)
                    shortcutPicker(selection: $controller.shortcuts.restore.key)
                }
                GridRow {
                    Text("フォーム")
                        .foregroundStyle(.secondary)
                    shortcutPicker(selection: $controller.shortcuts.formFill.key)
                }
                GridRow {
                    Text("メニュー")
                        .foregroundStyle(.secondary)
                    shortcutPicker(selection: $controller.shortcuts.quickMenu.key)
                }
            }

            Text("⌘ + ⇧ は固定です。キーだけ変更できます。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("クリップボード")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("クリップボード履歴を保存", isOn: $clipboardHistory.isEnabled)
                .help("テキストだけローカルに保存します。")

            HStack(spacing: 10) {
                Text("\(clipboardHistory.items.count)件保存中")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    controller.clearClipboardHistory()
                } label: {
                    Label("履歴を消去", systemImage: "trash")
                }
                .disabled(clipboardHistory.items.isEmpty)
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("プロフィール")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("返信にプロフィールを使う", isOn: $controller.userProfileEnabled)
                .help("オフのとき、プロフィール情報は返信生成リクエストに含めません。")

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("名前")
                        .foregroundStyle(.secondary)
                    TextField("名前を入力", text: $controller.userProfile.displayName)
                }
                GridRow {
                    Text("会社・組織")
                        .foregroundStyle(.secondary)
                    TextField("会社名・組織名", text: $controller.userProfile.companyName)
                }
                GridRow {
                    Text("部署")
                        .foregroundStyle(.secondary)
                    TextField("営業、プロダクトなど", text: $controller.userProfile.department)
                }
                GridRow {
                    Text("役割")
                        .foregroundStyle(.secondary)
                    TextField("代表、営業、PMなど", text: $controller.userProfile.role)
                }
                GridRow {
                    Text("メール")
                        .foregroundStyle(.secondary)
                    TextField("name@example.com", text: $controller.userProfile.email)
                }
                GridRow {
                    Text("電話")
                        .foregroundStyle(.secondary)
                    TextField("電話番号", text: $controller.userProfile.phone)
                }
                GridRow {
                    Text("Webサイト")
                        .foregroundStyle(.secondary)
                    TextField("https://...", text: $controller.userProfile.website)
                }
            }

            profileEditor("自己紹介・背景", text: $controller.userProfile.background)
            profileEditor("住所", text: $controller.userProfile.address)
            profileEditor("SNS・プロフィールURL", text: $controller.userProfile.socialURL)
            profileEditor("サービス説明", text: $controller.userProfile.serviceDescription)
            profileEditor("フォーム用メモ", text: $controller.userProfile.formFillNotes)
            profileEditor("文体", text: $controller.userProfile.writingStyle)
            profileEditor("使いたい表現", text: $controller.userProfile.preferredPhrases)
            profileEditor("避けたい表現", text: $controller.userProfile.avoidedPhrases)

            HStack(spacing: 8) {
                Button {
                    controller.importUserProfile()
                } label: {
                    Label("読み込み", systemImage: "square.and.arrow.down")
                }

                Button {
                    controller.exportUserProfile()
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }

                Spacer()

                Button(role: .destructive) {
                    controller.clearUserProfile()
                } label: {
                    Label("クリア", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func profileEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 13))
                .frame(minHeight: 54, maxHeight: 72)
                .scrollContentBackground(.hidden)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private enum VoiceTriggerKind: String, Hashable {
        case commandShift
        case fnCommand
        case commandSpace
    }

    private var voiceTriggerKind: Binding<VoiceTriggerKind> {
        Binding(
            get: {
                switch controller.shortcuts.voiceTrigger {
                case .fnCommand: .fnCommand
                case .commandShift: .commandShift
                case .commandSpace: .commandSpace
                }
            },
            set: { kind in
                switch kind {
                case .fnCommand:
                    controller.shortcuts.voiceTrigger = .fnCommand
                case .commandSpace:
                    controller.shortcuts.voiceTrigger = .commandSpace
                case .commandShift:
                    controller.shortcuts.voiceTrigger = .commandShift(controller.shortcuts.voice.key)
                }
            }
        )
    }

    private var voiceKeyBinding: Binding<HotKeyKey> {
        Binding(
            get: { controller.shortcuts.voice.key },
            set: { key in
                controller.shortcuts.voice = HotKeyShortcut(key: key)
                controller.shortcuts.voiceTrigger = .commandShift(key)
            }
        )
    }

    private func shortcutPicker(selection: Binding<HotKeyKey>) -> some View {
        Picker("ショートカット", selection: selection) {
            ForEach(HotKeyKey.allCases) { key in
                Text("⌘ + ⇧ + \(key.displayName)")
                    .tag(key)
                    .disabled(isShortcutKeyUsed(key, except: selection.wrappedValue))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func isShortcutKeyUsed(_ key: HotKeyKey, except current: HotKeyKey) -> Bool {
        guard key != current else {
            return false
        }
        if controller.shortcuts.rewrite.key == key
            || controller.shortcuts.restore.key == key
            || controller.shortcuts.formFill.key == key
            || controller.shortcuts.quickMenu.key == key {
            return true
        }
        if case .commandShift = controller.shortcuts.voiceTrigger {
            return controller.shortcuts.voice.key == key
        }
        return false
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("プロキシ")
                        .foregroundStyle(.secondary)
                    TextField("https://.../v1/rewrite", text: $controller.config.proxyURLString)
                }
                GridRow {
                    Text("キー")
                        .foregroundStyle(.secondary)
                    SecureField("共有シークレット", text: $controller.config.proxyAuthToken)
                }
            }
        }
    }
}
