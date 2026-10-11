import Carbon
import Foundation

/// Character lookup for one keyboard layout. Shortcuts are stored as physical key
/// codes, so the label has to come from the layout the user is typing with
/// (a JIS keyboard prints "@" where an ANSI keyboard prints "[").
public struct KeyboardLayout: Sendable {
    public let layoutData: Data
    public let keyboardType: UInt32

    public init(layoutData: Data, keyboardType: UInt32) {
        self.layoutData = layoutData
        self.keyboardType = keyboardType
    }

    /// The ASCII-capable layout behind the current input source. Japanese input
    /// methods report their Roman layout here, so letters stay readable.
    public static var current: KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        return KeyboardLayout(source: source, keyboardType: UInt32(LMGetKbdType()))
    }

    /// An installed layout by input source ID (for example `com.apple.keylayout.US`),
    /// even when it is not enabled in System Settings.
    public static func installed(id: String, keyboardType: UInt32) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard
            let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
            let source = list.first
        else {
            return nil
        }
        return KeyboardLayout(source: source, keyboardType: keyboardType)
    }

    /// First hardware keyboard type of the given physical kind (`kKeyboardANSI`,
    /// `kKeyboardJIS`, `kKeyboardISO`).
    public static func keyboardType(physicalLayout: Int) -> UInt32? {
        (UInt32(0)..<UInt32(256)).first { Int(KBGetLayoutType(Int16($0))) == physicalLayout }
    }

    private init?(source: TISInputSource, keyboardType: UInt32) {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        self.init(layoutData: data, keyboardType: keyboardType)
    }

    /// The unmodified character the key types, or nil for keys without a printable one.
    public func character(forKeyCode keyCode: UInt32) -> String? {
        layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else {
                return nil
            }
            let text = String(utf16CodeUnits: characters, count: length)
            let printable = text.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            return printable ? text : nil
        }
    }
}

/// Labels and classification for virtual key codes used by shortcuts.
public enum KeyCodeNames {
    public static let functionKeyCodes: [UInt32] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
    ].map(UInt32.init)

    private static let extendedFunctionKeyCodes: [UInt32] = [
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].map(UInt32.init)

    /// Keys that never type a character. Their names do not depend on the layout.
    private static let specialNames: [UInt32: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "↩",
            kVK_ANSI_KeypadEnter: "⌤",
            kVK_Tab: "⇥",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟",
            kVK_Help: "Help",
            kVK_ANSI_KeypadClear: "⌧",
            kVK_JIS_Eisu: "英数",
            kVK_JIS_Kana: "かな"
        ]
        for (index, code) in ([kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18,
                                kVK_F19, kVK_F20]).enumerated() {
            names[code] = "F\(index + 1)"
        }
        return Dictionary(uniqueKeysWithValues: names.map { (UInt32($0.key), $0.value) })
    }()

    /// US labels used when no layout is available (or the layout has no character).
    private static let ansiFallbackNames: [UInt32: String] = {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Grave: "`",
            kVK_JIS_Yen: "¥", kVK_JIS_Underscore: "_", kVK_JIS_KeypadComma: ",",
            kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
            kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
            kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadDecimal: ".",
            kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadMinus: "-",
            kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadEquals: "="
        ]
        return Dictionary(uniqueKeysWithValues: names.map { (UInt32($0.key), $0.value) })
    }()

    private static let keypadKeyCodes: Set<UInt32> = Set([
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEquals, kVK_JIS_KeypadComma
    ].map(UInt32.init))

    private static let modifierKeyCodes: Set<UInt32> = Set([
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_Function, kVK_CapsLock
    ].map(UInt32.init))

    /// macOS sets the fn flag on these keys by itself, so it must not count as
    /// an extra modifier when matching (⌘← arrives as fn + ⌘ + ←).
    private static let functionFlagKeyCodes: Set<UInt32> = Set([
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help
    ].map(UInt32.init)).union(functionKeyCodes).union(extendedFunctionKeyCodes)

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    public static func isModifierKey(_ keyCode: UInt32) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    public static func impliesFunctionFlag(_ keyCode: UInt32) -> Bool {
        functionFlagKeyCodes.contains(keyCode)
    }

    /// Key codes a shortcut may use: anything on the keyboard except modifier keys.
    public static func isSupportedKey(_ keyCode: UInt32) -> Bool {
        keyCode <= 0x7F && !isModifierKey(keyCode)
    }

    /// Whether the key types a character on its own (letters, digits, symbols,
    /// keypad). Space, ↩, arrows, F-keys, Esc and the like do not.
    public static func typesCharacter(_ keyCode: UInt32) -> Bool {
        isSupportedKey(keyCode) && specialNames[keyCode] == nil
    }

    public static func displayName(forKeyCode keyCode: UInt32, layout: KeyboardLayout? = .current) -> String {
        if let special = specialNames[keyCode] {
            return special
        }
        let base = layout?.character(forKeyCode: keyCode)?.uppercased()
            ?? ansiFallbackNames[keyCode]
            ?? "キー\(keyCode)"
        return keypadKeyCodes.contains(keyCode) ? "テンキー\(base)" : base
    }

    /// `NSMenuItem.keyEquivalent` string. AppKit's function-key characters are
    /// written out here so the core module does not depend on AppKit.
    public static func keyEquivalent(forKeyCode keyCode: UInt32, layout: KeyboardLayout? = .current) -> String {
        let functionKeyBase = 0xF704
        let named: [Int: Int] = [
            kVK_Space: 0x20, kVK_Return: 0x0D, kVK_ANSI_KeypadEnter: 0x03, kVK_Tab: 0x09,
            kVK_Delete: 0x08, kVK_ForwardDelete: 0xF728, kVK_Escape: 0x1B,
            kVK_UpArrow: 0xF700, kVK_DownArrow: 0xF701, kVK_LeftArrow: 0xF702, kVK_RightArrow: 0xF703,
            kVK_Home: 0xF729, kVK_End: 0xF72B, kVK_PageUp: 0xF72C, kVK_PageDown: 0xF72D, kVK_Help: 0xF746
        ]
        if let value = named[Int(keyCode)], let scalar = Unicode.Scalar(value) {
            return String(Character(scalar))
        }
        if let index = (functionKeyCodes + extendedFunctionKeyCodes).firstIndex(of: keyCode),
           let scalar = Unicode.Scalar(functionKeyBase + index) {
            return String(Character(scalar))
        }
        guard specialNames[keyCode] == nil else {
            return ""
        }
        return (layout?.character(forKeyCode: keyCode) ?? ansiFallbackNames[keyCode])?.lowercased() ?? ""
    }
}
