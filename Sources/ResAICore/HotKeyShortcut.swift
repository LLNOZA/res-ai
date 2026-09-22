import Carbon
import Foundation

public enum HotKeyKey: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case a
    case d
    case f
    case g
    case h
    case j
    case k
    case l
    case m
    case n
    case p
    case r
    case t
    case u
    case v
    case y
    case space

    public var id: String { rawValue }

    public var keyCode: UInt32 {
        switch self {
        case .space: UInt32(kVK_Space)
        case .a: UInt32(kVK_ANSI_A)
        case .d: UInt32(kVK_ANSI_D)
        case .f: UInt32(kVK_ANSI_F)
        case .g: UInt32(kVK_ANSI_G)
        case .h: UInt32(kVK_ANSI_H)
        case .j: UInt32(kVK_ANSI_J)
        case .k: UInt32(kVK_ANSI_K)
        case .l: UInt32(kVK_ANSI_L)
        case .m: UInt32(kVK_ANSI_M)
        case .n: UInt32(kVK_ANSI_N)
        case .p: UInt32(kVK_ANSI_P)
        case .r: UInt32(kVK_ANSI_R)
        case .t: UInt32(kVK_ANSI_T)
        case .u: UInt32(kVK_ANSI_U)
        case .v: UInt32(kVK_ANSI_V)
        case .y: UInt32(kVK_ANSI_Y)
        }
    }

    public var keyEquivalent: String {
        self == .space ? " " : rawValue
    }

    public var displayName: String {
        self == .space ? "Space" : rawValue.uppercased()
    }
}

public struct HotKeyShortcut: Codable, Equatable, Identifiable {
    public var key: HotKeyKey

    public init(key: HotKeyKey) {
        self.key = key
    }

    public var id: String {
        key.rawValue
    }

    public var keyCode: UInt32 {
        key.keyCode
    }

    public var modifiers: UInt32 {
        UInt32(cmdKey | shiftKey)
    }

    public var keyEquivalent: String {
        key.keyEquivalent
    }

    public var displayName: String {
        "⌘ + ⇧ + \(key.displayName)"
    }
}

public enum VoiceTrigger: Codable, Equatable, Hashable, Sendable {
    case commandShift(HotKeyKey)
    case fnCommand
    /// ⌘ + Space. Collides with Spotlight unless the user disables that system shortcut.
    case commandSpace

    public var displayName: String {
        switch self {
        case .commandShift(let key):
            HotKeyShortcut(key: key).displayName
        case .fnCommand:
            "fn + ⌘"
        case .commandSpace:
            "⌘ + Space"
        }
    }

    /// Key code / modifier pair for ⌘Space, for `GlobalHotKeyManager.register(keyCode:modifiers:)`.
    public static let commandSpaceKeyCode = UInt32(kVK_Space)
    public static let commandSpaceModifiers = UInt32(cmdKey)
}

public struct AppShortcuts: Codable, Equatable {
    public var rewrite: HotKeyShortcut
    public var restore: HotKeyShortcut
    public var formFill: HotKeyShortcut
    public var quickMenu: HotKeyShortcut
    public var voice: HotKeyShortcut
    public var voiceTrigger: VoiceTrigger

    public init(
        rewrite: HotKeyShortcut = HotKeyShortcut(key: .j),
        restore: HotKeyShortcut = HotKeyShortcut(key: .u),
        formFill: HotKeyShortcut = HotKeyShortcut(key: .k),
        quickMenu: HotKeyShortcut = HotKeyShortcut(key: .v),
        voice: HotKeyShortcut = HotKeyShortcut(key: .space),
        voiceTrigger: VoiceTrigger? = nil
    ) {
        self.rewrite = rewrite
        self.restore = restore
        self.formFill = formFill
        self.quickMenu = quickMenu
        self.voice = voice
        self.voiceTrigger = voiceTrigger ?? .commandShift(voice.key)
        if case .commandShift(let key) = self.voiceTrigger {
            self.voice = HotKeyShortcut(key: key)
        }
    }

    public static var defaults: AppShortcuts {
        AppShortcuts()
    }

    public var hasConflicts: Bool {
        var keys = [rewrite.key, restore.key, formFill.key, quickMenu.key]
        if case .commandShift = voiceTrigger {
            keys.append(voice.key)
        }
        return Set(keys).count < keys.count
    }

    public func sanitized() -> AppShortcuts {
        var sanitized = self
        var used = Set<HotKeyKey>()
        sanitized.rewrite = uniqueShortcut(rewrite, fallback: .j, used: &used)
        sanitized.restore = uniqueShortcut(restore, fallback: .u, used: &used)
        sanitized.formFill = uniqueShortcut(formFill, fallback: .k, used: &used)
        sanitized.quickMenu = uniqueShortcut(quickMenu, fallback: .v, used: &used)
        if case .commandShift = voiceTrigger {
            sanitized.voice = uniqueShortcut(voice, fallback: .space, used: &used)
            sanitized.voiceTrigger = .commandShift(sanitized.voice.key)
        }
        return sanitized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rewrite = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .rewrite)
            ?? HotKeyShortcut(key: .j)
        restore = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .restore)
            ?? HotKeyShortcut(key: .u)
        formFill = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .formFill)
            ?? HotKeyShortcut(key: .k)
        quickMenu = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .quickMenu)
            ?? HotKeyShortcut(key: .v)
        voice = try container.decodeIfPresent(HotKeyShortcut.self, forKey: .voice)
            ?? HotKeyShortcut(key: .space)
        voiceTrigger = try container.decodeIfPresent(VoiceTrigger.self, forKey: .voiceTrigger)
            ?? .commandShift(voice.key)
        if case .commandShift(let key) = voiceTrigger {
            voice = HotKeyShortcut(key: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rewrite, forKey: .rewrite)
        try container.encode(restore, forKey: .restore)
        try container.encode(formFill, forKey: .formFill)
        try container.encode(quickMenu, forKey: .quickMenu)
        try container.encode(voice, forKey: .voice)
        try container.encode(voiceTrigger, forKey: .voiceTrigger)
    }

    public static func load(defaults: UserDefaults = .standard) -> AppShortcuts {
        guard
            let data = defaults.data(forKey: DefaultsKey.shortcuts),
            let decoded = try? JSONDecoder().decode(AppShortcuts.self, from: data)
        else {
            return .defaults
        }
        return decoded.sanitized()
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sanitized()) else {
            return
        }
        defaults.set(data, forKey: DefaultsKey.shortcuts)
    }

    private func uniqueShortcut(
        _ shortcut: HotKeyShortcut,
        fallback: HotKeyKey,
        used: inout Set<HotKeyKey>
    ) -> HotKeyShortcut {
        if used.insert(shortcut.key).inserted {
            return shortcut
        }

        if used.insert(fallback).inserted {
            return HotKeyShortcut(key: fallback)
        }

        let firstAvailable = HotKeyKey.allCases.first { !used.contains($0) } ?? fallback
        used.insert(firstAvailable)
        return HotKeyShortcut(key: firstAvailable)
    }

    public enum DefaultsKey {
        public static let shortcuts = "shortcuts.v1"
    }

    private enum CodingKeys: String, CodingKey {
        case rewrite
        case restore
        case formFill
        case quickMenu
        case voice
        case voiceTrigger
    }
}
