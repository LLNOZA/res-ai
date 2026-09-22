import Foundation

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var recognized: String
    public var preferred: String

    public init(id: UUID = UUID(), recognized: String, preferred: String) {
        self.id = id
        self.recognized = recognized
        self.preferred = preferred
    }
}

public struct UserDictionary: Codable, Equatable, Sendable {
    public var entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    public func apply(to text: String) -> String {
        let replacements = entries.enumerated()
            .filter { !$0.element.recognized.isEmpty && !$0.element.preferred.isEmpty }
            .sorted { lhs, rhs in
                if lhs.element.recognized.count != rhs.element.recognized.count {
                    return lhs.element.recognized.count > rhs.element.recognized.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var result = text
        for entry in replacements {
            result = result.replacingOccurrences(of: entry.recognized, with: entry.preferred)
        }
        return result
    }

    public func promptText() -> String {
        let replacements = entries.compactMap { entry -> String? in
            guard !entry.recognized.isEmpty, !entry.preferred.isEmpty else {
                return nil
            }
            return "\(entry.recognized) → \(entry.preferred)"
        }
        let vocabulary = entries.compactMap { entry -> String? in
            guard entry.recognized.isEmpty, !entry.preferred.isEmpty else {
                return nil
            }
            return entry.preferred
        }

        var blocks: [String] = []
        if !replacements.isEmpty {
            blocks.append("置換ルール:\n" + replacements.joined(separator: "\n"))
        }
        if !vocabulary.isEmpty {
            blocks.append(
                "よく使う語彙（同音・類似の誤認識はこの表記に寄せる）:\n"
                    + vocabulary.joined(separator: ", ")
            )
        }
        return blocks.joined(separator: "\n")
    }

    public mutating func addVocabulary(_ raw: String) {
        var separators = CharacterSet.newlines
        separators.insert(charactersIn: ",、")
        let tokens = raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set(entries.map { $0.preferred.lowercased() })
        for token in tokens {
            let key = token.lowercased()
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            entries.append(DictionaryEntry(recognized: "", preferred: token))
        }
    }

    public static func isValid(_ entry: DictionaryEntry) -> Bool {
        !entry.preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func load(defaults: UserDefaults = .standard) -> UserDictionary {
        guard
            let data = defaults.data(forKey: DefaultsKey.dictionary),
            let dictionary = try? JSONDecoder().decode(UserDictionary.self, from: data)
        else {
            return UserDictionary()
        }
        return dictionary
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }
        defaults.set(data, forKey: DefaultsKey.dictionary)
    }

    public enum DefaultsKey {
        public static let dictionary = "dictation.dictionary.v1"
    }
}
