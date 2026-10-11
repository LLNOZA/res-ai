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
                    aiConnectionSection

                    Divider()

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
                    controller.requestHotKeyPermissionsFromUserAction()
                } label: {
                    Label("操作権限", systemImage: "hand.raised")
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

            Toggle("AI で整える", isOn: $voiceInput.settings.cleanupEnabled)
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

            Text(cleanupRouteNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("入力欄の上の文脈を整えの参考に送る", isOn: $voiceInput.settings.includeScreenContext)
                .help("同音異義語の判断のために、入力欄の上に見えている数行をテキストで送ります。音声は送りません。")

            HStack(spacing: 8) {
                Button {
                    voiceInput.saveSettings()
                    voiceInput.testCleanupConnection()
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

    private var cleanupRouteNote: String {
        if controller.hasClaudeAPIKey {
            return "整えは Claude API で直接行います。Gemini APIキーは Claude APIキーとAIプロキシがどちらも未設定のときだけ使用します。"
        }
        if controller.config.proxyURL != nil {
            return "整えは AIプロキシ経由で行います。Gemini APIキーはプロキシ未設定時のみ使用します。"
        }
        return "Claude APIキーとAIプロキシが未設定のため、整えは Gemini APIキーで直接行います（キーが空なら整えずに生テキストのまま）。"
    }

    private var aiConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI接続")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("返信生成・フォーム入力・音声入力の整えは、ここで設定した自分の Claude APIキーで直接 Claude API を呼びます。キーはキーチェーンにだけ保存します。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Claude APIキー")
                        .foregroundStyle(.secondary)
                    SecureField(
                        controller.hasClaudeAPIKey ? "設定済み（変更する場合のみ入力）" : "sk-ant-...",
                        text: $controller.claudeAPIKeyInput
                    )
                    .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("現在の経路")
                        .foregroundStyle(.secondary)
                    Text(controller.activeAIRoute.displayName)
                        .font(.system(size: 12, weight: .medium))
                }
            }

            HStack(spacing: 8) {
                Button {
                    controller.saveClaudeAPIKey()
                } label: {
                    Label("キーを保存", systemImage: "key")
                }
                .disabled(controller.claudeAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(role: .destructive) {
                    controller.deleteClaudeAPIKey()
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(!controller.hasClaudeAPIKey)
                Button {
                    controller.testClaudeConnection()
                } label: {
                    Label("接続テスト", systemImage: "antenna.radiowaves.left.and.right")
                }
                if let result = controller.claudeConnectionTestResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.bordered)

            Text("Claude APIキーが未設定の場合は、詳細接続設定のAIプロキシ（移行期間の互換用）を使います。どちらも無い場合はプレビュー動作です。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

            HStack(spacing: 10) {
                Button {
                    controller.exportDiagnostics()
                } label: {
                    Label("診断情報を書き出す", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }

            Text("ログ・クラッシュ診断・OS とアプリのバージョンを zip にしてデスクトップに保存します。入力・コピーした文章は含みません（上のテキストプレビュー保存がオンの場合を除く）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ショートカット")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                ForEach(ShortcutAction.allCases) { action in
                    GridRow {
                        Text(action.displayName)
                            .foregroundStyle(.secondary)
                        shortcutRow(action)
                    }
                }
            }

            Text("欄をクリックして、使いたいキーの組み合わせを押してください。Esc で中止。修飾キーだけ（例: fn + ⌘、⌃）で登録するときは、押して離すと確定します。文字を入力できなくなるなど影響がある組み合わせは、登録前に確認します。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    controller.resetAllShortcuts()
                } label: {
                    Label("すべて標準に戻す", systemImage: "arrow.counterclockwise")
                }
                .disabled(controller.shortcuts == .defaults)

                if let error = controller.shortcutResetError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ShortcutRecorderField(
                    displayName: controller.shortcuts.trigger(for: action).displayName,
                    isRecording: controller.recordingShortcutAction == action,
                    onStart: { controller.beginRecordingShortcut(action) },
                    onCapture: { controller.finishRecordingShortcut($0, for: action) },
                    onCancel: { controller.cancelRecordingShortcut(action) }
                )

                Button {
                    controller.resetShortcut(action)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("標準に戻す（\(AppShortcuts.defaults.trigger(for: action).displayName)）")
                .disabled(controller.shortcuts.isDefault(action))
            }

            if let error = controller.shortcutErrors[action] {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(shortcutNotes(for: action), id: \.self) { note in
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Warnings the user already agreed to, kept under the row, plus system
    /// settings the trigger depends on.
    private func shortcutNotes(for action: ShortcutAction) -> [String] {
        let trigger = controller.shortcuts.trigger(for: action)
        var notes: [String] = []
        if case .modifierChord = trigger, action == .voice, voiceInput.settings.activationMode == .holdOrTap {
            notes.append("\(trigger.displayName) を押している間だけ聞き取ります。押している間に他のキーを押すと取り消します。")
        } else if let warning = trigger.warning {
            notes.append(warning.note)
        }
        if case .modifierChord(let modifiers) = trigger, modifiers.contains(.function) {
            notes.append("システム設定 > キーボード >「🌐 キーを押して」を「何もしない」にしてください（音声入力/絵文字が開くのを防ぐため）")
        }
        if case .key(let shortcut) = trigger, ReservedShortcut.matching(shortcut) != nil {
            notes.append("システムのショートカットと競合する場合は、システム設定 > キーボード > キーボードショートカットで該当する項目をオフにしてください。")
        }
        return notes
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
