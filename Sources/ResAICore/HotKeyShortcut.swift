import Carbon
import CoreGraphics
import Foundation

/// Modifier keys a shortcut requires. Saved by name so stored settings stay readable.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let function = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)
    public static let shift = ShortcutModifiers(rawValue: 1 << 4)

    /// Display order keeps the app's existing "⌘ + ⇧ + J" and "fn + ⌘" labels.
    private static let ordered: [(modifier: ShortcutModifiers, symbol: String, name: String)] = [
        (.function, "fn", "function"),
        (.control, "⌃", "control"),
        (.option, "⌥", "option"),
        (.command, "⌘", "command"),
        (.shift, "⇧", "shift")
    ]

    public init(eventFlags: CGEventFlags) {
        var modifiers: ShortcutModifiers = []
        if eventFlags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        if eventFlags.contains(.maskControl) { modifiers.insert(.control) }
        if eventFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        if eventFlags.contains(.maskCommand) { modifiers.insert(.command) }
        if eventFlags.contains(.maskShift) { modifiers.insert(.shift) }
        self = modifiers
    }

    public var symbols: [String] {
        Self.ordered.filter { contains($0.modifier) }.map(\.symbol)
    }

    public var count: Int {
        Self.ordered.filter { contains($0.modifier) }.count
    }

    /// Carbon modifier bits for `GlobalHotKeyManager.register(keyCode:modifiers:)`.
    /// Carbon has no fn bit; fn only appears in modifier-only chords.
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    public var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    fileprivate var names: [String] {
        Self.ordered.filter { contains($0.modifier) }.map(\.name)
    }

    fileprivate init?(names: [String]) {
        var modifiers: ShortcutModifiers = []
        for name in names {
            guard let match = Self.ordered.first(where: { $0.name == name }) else {
                return nil
            }
            modifiers.insert(match.modifier)
        }
        self = modifiers
    }
}

extension ShortcutModifiers: Codable {
    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        guard let modifiers = ShortcutModifiers(names: names) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown modifier name"
            ))
        }
        self = modifiers
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(names)
    }
}

/// A key (virtual key code, layout independent) plus the modifiers held with it.
public struct HotKeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The pre-0.4.1 shape: ⌘ + ⇧ + key.
    public static func commandShift(_ keyCode: Int) -> HotKeyShortcut {
        HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: [.command, .shift])
    }

    public var carbonModifiers: UInt32 {
        modifiers.carbonFlags
    }

    public var keyEquivalent: String {
        KeyCodeNames.keyEquivalent(forKeyCode: keyCode)
    }

    public var displayName: String {
        displayName(layout: .current)
    }

    public func displayName(layout: KeyboardLayout?) -> String {
        (modifiers.symbols + [KeyCodeNames.displayName(forKeyCode: keyCode, layout: layout)])
            .joined(separator: " + ")
    }

    /// Shape a stored shortcut must have to be registered at all. Anything else
    /// (no modifier, ⇧ only, system shortcuts) is allowed after a warning.
    var isRegistrable: Bool {
        KeyCodeNames.isSupportedKey(keyCode) && !modifiers.contains(.function)
    }
}

/// What a recorder field produces: a key combination, or modifiers alone.
public enum ShortcutTrigger: Hashable, Sendable {
    case key(HotKeyShortcut)
    /// Modifier-only chord such as fn + ⌘ or a single ⌃. Detected from
    /// `flagsChanged`, never swallowed.
    case modifierChord(ShortcutModifiers)

    public static let fnCommand = ShortcutTrigger.modifierChord([.function, .command])

    public var displayName: String {
        switch self {
        case .key(let shortcut):
            shortcut.displayName
        case .modifierChord(let modifiers):
            modifiers.symbols.joined(separator: " + ")
        }
    }

    public var keyShortcut: HotKeyShortcut? {
        if case .key(let shortcut) = self {
            return shortcut
        }
        return nil
    }

    var isRegistrable: Bool {
        switch self {
        case .key(let shortcut):
            shortcut.isRegistrable
        case .modifierChord(let modifiers):
            !modifiers.isEmpty
        }
    }

    /// What the user gives up with this trigger, or nil when nothing is lost.
    public var warning: ShortcutWarning? {
        warning(layout: .current)
    }

    public func warning(layout: KeyboardLayout?) -> ShortcutWarning? {
        switch self {
        case .modifierChord:
            return .modifierOnly(displayName)
        case .key(let shortcut):
            let keyName = KeyCodeNames.displayName(forKeyCode: shortcut.keyCode, layout: layout)
            let typesCharacter = KeyCodeNames.typesCharacter(shortcut.keyCode)
            if shortcut.modifiers.isEmpty {
                return typesCharacter ? .typesCharacter(keyName) : .replacesKey(keyName)
            }
            if shortcut.modifiers == [.shift] {
                let name = shortcut.displayName(layout: layout)
                guard typesCharacter else {
                    return .replacesKey(name)
                }
                let character = layout?.character(forKeyCode: shortcut.keyCode) ?? keyName
                let isLetter = character.lowercased() != character.uppercased()
                return isLetter ? .uppercase(keyName) : .shiftedCharacter(name)
            }
            if let reserved = ReservedShortcut.matching(shortcut) {
                return .reserved(reserved.name)
            }
            return nil
        }
    }
}

/// Shown as a confirmation before registering, then as a gray note under the row.
public enum ShortcutWarning: Equatable, Sendable {
    /// A character key alone, e.g. J.
    case typesCharacter(String)
    /// A non-character key alone or with ⇧ only, e.g. F5, Space, ⇧ + ←.
    case replacesKey(String)
    /// ⇧ + letter.
    case uppercase(String)
    /// ⇧ + a non-letter character key, e.g. ⇧ + 1.
    case shiftedCharacter(String)
    /// One of `ReservedShortcut.all`.
    case reserved(String)
    /// Modifiers alone, e.g. ⌘ + ⇧.
    case modifierOnly(String)

    /// Sentence for the confirmation dialog.
    public var confirmationMessage: String {
        switch self {
        case .typesCharacter(let key):
            "この組み合わせにすると「\(key)」が入力できなくなります。登録しますか？"
        case .replacesKey(let key):
            "この組み合わせにすると \(key) 本来の動作ができなくなります。登録しますか？"
        case .uppercase(let key):
            "この組み合わせにすると大文字の「\(key)」が入力できなくなります。登録しますか？"
        case .shiftedCharacter(let combination):
            "この組み合わせにすると \(combination) で入力する記号が入力できなくなります。登録しますか？"
        case .reserved(let name):
            "この組み合わせにすると macOS・定番のショートカット（\(name)）が使えなくなります。登録しますか？"
        case .modifierOnly(let combination):
            "\(combination) を単独で押して離したときに動作します。押している間に他のキーやクリックをしたときは動作しません。登録しますか？"
        }
    }

    /// Note kept under the settings row after the user agreed.
    public var note: String {
        switch self {
        case .typesCharacter(let key):
            "「\(key)」が入力できなくなっています"
        case .replacesKey(let key):
            "\(key) 本来の動作ができなくなっています"
        case .uppercase(let key):
            "大文字の「\(key)」が入力できなくなっています"
        case .shiftedCharacter(let combination):
            "\(combination) で入力する記号が入力できなくなっています"
        case .reserved(let name):
            "macOS・定番のショートカット（\(name)）が使えなくなっています"
        case .modifierOnly(let combination):
            "\(combination) を単独で押して離したときに動作します"
        }
    }
}

extension ShortcutTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case keyCode
        case modifiers
    }

    private enum Kind: String, Codable {
        case key
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)
        // Non-voice actions stored a bare `HotKeyShortcut` (no "type") before
        // they could use modifier-only chords.
        switch try container.decodeIfPresent(Kind.self, forKey: .type) ?? .key {
        case .key:
            let keyCode = try container.decode(UInt32.self, forKey: .keyCode)
            self = .key(HotKeyShortcut(keyCode: keyCode, modifiers: modifiers))
        case .modifiers:
            self = .modifierChord(modifiers)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .key(let shortcut):
            try container.encode(Kind.key, forKey: .type)
            try container.encode(shortcut.keyCode, forKey: .keyCode)
            try container.encode(shortcut.modifiers, forKey: .modifiers)
        case .modifierChord(let modifiers):
            try container.encode(Kind.modifiers, forKey: .type)
            try container.encode(modifiers, forKey: .modifiers)
        }
    }
}

public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case voice
    case rewrite
    case restore
    case formFill
    case quickMenu

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .voice: "音声入力"
        case .rewrite: "返信"
        case .restore: "復元"
        case .formFill: "フォーム"
        case .quickMenu: "メニュー"
        }
    }
}

/// A macOS or commonly used app shortcut. Taking one over is allowed after a
/// warning (`ShortcutWarning.reserved`).
public struct ReservedShortcut: Equatable, Sendable {
    public let shortcut: HotKeyShortcut
    public let name: String

    public init(_ keyCode: Int, _ modifiers: ShortcutModifiers, _ name: String) {
        self.shortcut = HotKeyShortcut(keyCode: UInt32(keyCode), modifiers: modifiers)
        self.name = name
    }

    /// Matched by physical key position (ANSI/JIS share letter positions).
    public static let all: [ReservedShortcut] = [
        ReservedShortcut(kVK_ANSI_Q, [.command], "終了"),
        ReservedShortcut(kVK_ANSI_W, [.command], "ウインドウを閉じる"),
        ReservedShortcut(kVK_ANSI_C, [.command], "コピー"),
        ReservedShortcut(kVK_ANSI_V, [.command], "ペースト"),
        ReservedShortcut(kVK_ANSI_X, [.command], "カット"),
        ReservedShortcut(kVK_ANSI_Z, [.command], "取り消す"),
        ReservedShortcut(kVK_ANSI_Z, [.command, .shift], "やり直す"),
        ReservedShortcut(kVK_ANSI_A, [.command], "すべてを選択"),
        ReservedShortcut(kVK_ANSI_S, [.command], "保存"),
        ReservedShortcut(kVK_ANSI_N, [.command], "新規"),
        ReservedShortcut(kVK_ANSI_O, [.command], "開く"),
        ReservedShortcut(kVK_ANSI_P, [.command], "プリント"),
        ReservedShortcut(kVK_ANSI_F, [.command], "検索"),
        ReservedShortcut(kVK_ANSI_T, [.command], "新規タブ"),
        ReservedShortcut(kVK_ANSI_H, [.command], "隠す"),
        ReservedShortcut(kVK_ANSI_M, [.command], "しまう"),
        ReservedShortcut(kVK_ANSI_Comma, [.command], "設定"),
        ReservedShortcut(kVK_Tab, [.command], "アプリ切り替え"),
        ReservedShortcut(kVK_Tab, [.command, .shift], "アプリ切り替え"),
        ReservedShortcut(kVK_Space, [.command], "Spotlight"),
        ReservedShortcut(kVK_Space, [.command, .option], "Finder 検索"),
        ReservedShortcut(kVK_Space, [.control], "入力ソース切り替え"),
        ReservedShortcut(kVK_Space, [.control, .option], "入力ソース切り替え"),
        ReservedShortcut(kVK_Space, [.control, .command], "絵文字と記号"),
        ReservedShortcut(kVK_ANSI_3, [.command, .shift], "スクリーンショット"),
        ReservedShortcut(kVK_ANSI_4, [.command, .shift], "スクリーンショット"),
        ReservedShortcut(kVK_ANSI_5, [.command, .shift], "スクリーンショット"),
        ReservedShortcut(kVK_ANSI_3, [.command, .shift, .control], "スクリーンショット"),
        ReservedShortcut(kVK_ANSI_4, [.command, .shift, .control], "スクリーンショット"),
        ReservedShortcut(kVK_Escape, [.command, .option], "強制終了"),
        ReservedShortcut(kVK_ANSI_Q, [.command, .control], "画面ロック"),
        ReservedShortcut(kVK_ANSI_F, [.command, .control], "フルスクリーン"),
        ReservedShortcut(kVK_ANSI_D, [.command, .option], "Dock を隠す")
    ]

    public static func matching(_ shortcut: HotKeyShortcut) -> ReservedShortcut? {
        all.first { $0.shortcut == shortcut }
    }
}

/// Only these are refused; every other combination is allowed (some after a
/// `ShortcutWarning` confirmation).
public enum ShortcutValidationError: LocalizedError, Equatable {
    case nothingPressed
    case unsupportedKey
    case duplicate(ShortcutAction)

    public var errorDescription: String? {
        switch self {
        case .nothingPressed:
            "キーが押されていません。"
        case .unsupportedKey:
            "このキーはショートカットに使えません。"
        case .duplicate(let action):
            "「\(action.displayName)」で使用中です。"
        }
    }
}

public struct AppShortcuts: Codable, Equatable {
    public var rewrite: ShortcutTrigger
    public var restore: ShortcutTrigger
    public var formFill: ShortcutTrigger
    public var quickMenu: ShortcutTrigger
    public var voiceTrigger: ShortcutTrigger

    public static let defaultRewrite = ShortcutTrigger.key(.commandShift(kVK_ANSI_J))
    public static let defaultRestore = ShortcutTrigger.key(.commandShift(kVK_ANSI_U))
    public static let defaultFormFill = ShortcutTrigger.key(.commandShift(kVK_ANSI_K))
    public static let defaultQuickMenu = ShortcutTrigger.key(.commandShift(kVK_ANSI_V))
    public static let defaultVoiceTrigger = ShortcutTrigger.key(.commandShift(kVK_Space))

    public init(
        rewrite: ShortcutTrigger = AppShortcuts.defaultRewrite,
        restore: ShortcutTrigger = AppShortcuts.defaultRestore,
        formFill: ShortcutTrigger = AppShortcuts.defaultFormFill,
        quickMenu: ShortcutTrigger = AppShortcuts.defaultQuickMenu,
        voiceTrigger: ShortcutTrigger = AppShortcuts.defaultVoiceTrigger
    ) {
        self.rewrite = rewrite
        self.restore = restore
        self.formFill = formFill
        self.quickMenu = quickMenu
        self.voiceTrigger = voiceTrigger
    }

    public static var defaults: AppShortcuts {
        AppShortcuts()
    }

    public func trigger(for action: ShortcutAction) -> ShortcutTrigger {
        switch action {
        case .voice: voiceTrigger
        case .rewrite: rewrite
        case .restore: restore
        case .formFill: formFill
        case .quickMenu: quickMenu
        }
    }

    /// Stores `trigger` for `action`; call `validationError` first.
    public mutating func set(_ trigger: ShortcutTrigger, for action: ShortcutAction) {
        switch action {
        case .voice: voiceTrigger = trigger
        case .rewrite: rewrite = trigger
        case .restore: restore = trigger
        case .formFill: formFill = trigger
        case .quickMenu: quickMenu = trigger
        }
    }

    public func isDefault(_ action: ShortcutAction) -> Bool {
        trigger(for: action) == AppShortcuts.defaults.trigger(for: action)
    }

    /// Why `trigger` cannot be recorded for `action`, or nil when it can.
    /// Risky but usable combinations are reported by `ShortcutTrigger.warning`.
    public func validationError(for trigger: ShortcutTrigger, action: ShortcutAction) -> ShortcutValidationError? {
        switch trigger {
        case .modifierChord(let modifiers):
            if modifiers.isEmpty {
                return .nothingPressed
            }
        case .key(let shortcut):
            guard shortcut.isRegistrable else {
                return .unsupportedKey
            }
        }
        for other in ShortcutAction.allCases where other != action {
            if self.trigger(for: other) == trigger {
                return .duplicate(other)
            }
        }
        return nil
    }

    public var hasConflicts: Bool {
        let triggers = ShortcutAction.allCases.map { trigger(for: $0) }
        return Set(triggers).count < triggers.count
    }

    /// Repairs stored data that cannot be registered: unusable shapes and
    /// duplicates fall back to the defaults (then to other free ⌘ + ⇧ letters).
    public func sanitized() -> AppShortcuts {
        var sanitized = self
        var used = Set<ShortcutTrigger>()
        sanitized.rewrite = uniqueTrigger(rewrite, fallbacks: [Self.defaultRewrite], used: &used)
        sanitized.restore = uniqueTrigger(restore, fallbacks: [Self.defaultRestore], used: &used)
        sanitized.formFill = uniqueTrigger(formFill, fallbacks: [Self.defaultFormFill], used: &used)
        sanitized.quickMenu = uniqueTrigger(quickMenu, fallbacks: [Self.defaultQuickMenu], used: &used)
        sanitized.voiceTrigger = uniqueTrigger(
            voiceTrigger,
            fallbacks: [Self.defaultVoiceTrigger, .fnCommand],
            used: &used
        )
        return sanitized
    }

    private func uniqueTrigger(
        _ trigger: ShortcutTrigger,
        fallbacks: [ShortcutTrigger],
        used: inout Set<ShortcutTrigger>
    ) -> ShortcutTrigger {
        if trigger.isRegistrable, used.insert(trigger).inserted {
            return trigger
        }

        for fallback in fallbacks where used.insert(fallback).inserted {
            return fallback
        }

        let firstAvailable = Self.fallbackLetters
            .map { ShortcutTrigger.key(.commandShift($0)) }
            .first { !used.contains($0) } ?? fallbacks[0]
        used.insert(firstAvailable)
        return firstAvailable
    }

    private static let fallbackLetters = [
        kVK_ANSI_A, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_L,
        kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_P, kVK_ANSI_R, kVK_ANSI_Y
    ]

    // MARK: Persistence

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported shortcut format \(version)"
            )
        }
        rewrite = try container.decodeIfPresent(ShortcutTrigger.self, forKey: .rewrite) ?? Self.defaultRewrite
        restore = try container.decodeIfPresent(ShortcutTrigger.self, forKey: .restore) ?? Self.defaultRestore
        formFill = try container.decodeIfPresent(ShortcutTrigger.self, forKey: .formFill) ?? Self.defaultFormFill
        quickMenu = try container.decodeIfPresent(ShortcutTrigger.self, forKey: .quickMenu) ?? Self.defaultQuickMenu
        voiceTrigger = try container.decodeIfPresent(ShortcutTrigger.self, forKey: .voice) ?? Self.defaultVoiceTrigger
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(UntypedKeyTrigger(rewrite), forKey: .rewrite)
        try container.encode(UntypedKeyTrigger(restore), forKey: .restore)
        try container.encode(UntypedKeyTrigger(formFill), forKey: .formFill)
        try container.encode(UntypedKeyTrigger(quickMenu), forKey: .quickMenu)
        try container.encode(voiceTrigger, forKey: .voice)
    }

    /// Writes key shortcuts of the non-voice actions in their original bare
    /// shape (`{"keyCode":…,"modifiers":[…]}`); chords carry `"type"`.
    private struct UntypedKeyTrigger: Encodable {
        let trigger: ShortcutTrigger

        init(_ trigger: ShortcutTrigger) {
            self.trigger = trigger
        }

        func encode(to encoder: Encoder) throws {
            if case .key(let shortcut) = trigger {
                try shortcut.encode(to: encoder)
            } else {
                try trigger.encode(to: encoder)
            }
        }
    }

    /// Reads `shortcuts.v2`; when it has never been written, converts the
    /// pre-0.4.1 `shortcuts.v1` payload to the same shortcuts. Anything that
    /// cannot be read falls back to the defaults.
    public static func load(defaults: UserDefaults = .standard) -> AppShortcuts {
        if let data = defaults.data(forKey: DefaultsKey.shortcuts) {
            guard let decoded = try? JSONDecoder().decode(AppShortcuts.self, from: data) else {
                return .defaults
            }
            return decoded.sanitized()
        }
        if let legacy = defaults.data(forKey: DefaultsKey.legacyShortcuts) {
            return migrateLegacy(legacy) ?? .defaults
        }
        return .defaults
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sanitized()) else {
            return
        }
        defaults.set(data, forKey: DefaultsKey.shortcuts)
    }

    /// v1 stored ⌘ + ⇧ + letter only, plus three voice trigger kinds.
    public static func migrateLegacy(_ data: Data) -> AppShortcuts? {
        guard let legacy = try? JSONDecoder().decode(LegacyShortcutsV1.self, from: data) else {
            return nil
        }
        return legacy.migrated().sanitized()
    }

    public static let formatVersion = 2

    public enum DefaultsKey {
        public static let shortcuts = "shortcuts.v2"
        /// Written by 0.4.0 and earlier. Left in place so a downgrade keeps working.
        public static let legacyShortcuts = "shortcuts.v1"
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case rewrite
        case restore
        case formFill
        case quickMenu
        case voice
    }
}

/// Decoder for the pre-0.4.1 payload, e.g.
/// `{"rewrite":{"key":"j"}, …, "voiceTrigger":{"commandShift":{"_0":"space"}}}`.
private struct LegacyShortcutsV1: Decodable {
    enum Key: String, Decodable {
        case a, d, f, g, h, j, k, l, m, n, p, r, t, u, v, y, space

        var keyCode: Int {
            switch self {
            case .space: kVK_Space
            case .a: kVK_ANSI_A
            case .d: kVK_ANSI_D
            case .f: kVK_ANSI_F
            case .g: kVK_ANSI_G
            case .h: kVK_ANSI_H
            case .j: kVK_ANSI_J
            case .k: kVK_ANSI_K
            case .l: kVK_ANSI_L
            case .m: kVK_ANSI_M
            case .n: kVK_ANSI_N
            case .p: kVK_ANSI_P
            case .r: kVK_ANSI_R
            case .t: kVK_ANSI_T
            case .u: kVK_ANSI_U
            case .v: kVK_ANSI_V
            case .y: kVK_ANSI_Y
            }
        }
    }

    struct Shortcut: Decodable {
        var key: Key
    }

    /// Same synthesized coding as the old `VoiceTrigger` enum.
    enum VoiceTrigger: Decodable {
        case commandShift(Key)
        case fnCommand
        case commandSpace
    }

    var rewrite: Shortcut?
    var restore: Shortcut?
    var formFill: Shortcut?
    var quickMenu: Shortcut?
    var voice: Shortcut?
    var voiceTrigger: VoiceTrigger?

    func migrated() -> AppShortcuts {
        let voiceKey = voice?.key ?? .space
        let trigger: ShortcutTrigger
        switch voiceTrigger ?? .commandShift(voiceKey) {
        case .commandShift(let key):
            trigger = .key(.commandShift(key.keyCode))
        case .fnCommand:
            trigger = .fnCommand
        case .commandSpace:
            trigger = .key(HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: [.command]))
        }
        return AppShortcuts(
            rewrite: .key(.commandShift((rewrite?.key ?? .j).keyCode)),
            restore: .key(.commandShift((restore?.key ?? .u).keyCode)),
            formFill: .key(.commandShift((formFill?.key ?? .k).keyCode)),
            quickMenu: .key(.commandShift((quickMenu?.key ?? .v).keyCode)),
            voiceTrigger: trigger
        )
    }
}
