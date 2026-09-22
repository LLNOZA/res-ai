import Foundation

/// Locale + analyzer-format metadata computed during `prepare()`.
///
/// `SpeechAnalyzerDictationEngine` keeps the live `AVAudioFormat` separately;
/// this value type is the testable, Sendable view of the same cache.
public struct PreparedLocaleCache: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var requestedIdentifier: String
        public var resolvedIdentifier: String
        public var sampleRate: Double
        public var channelCount: UInt32

        public init(
            requestedIdentifier: String,
            resolvedIdentifier: String,
            sampleRate: Double,
            channelCount: UInt32
        ) {
            self.requestedIdentifier = requestedIdentifier
            self.resolvedIdentifier = resolvedIdentifier
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    private var entriesByRequested: [String: Entry] = [:]
    private var entriesByResolved: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool {
        entriesByRequested.isEmpty
    }

    public func entry(for locale: Locale) -> Entry? {
        let key = Self.identifier(locale)
        return entriesByRequested[key] ?? entriesByResolved[key]
    }

    public func isPrepared(for locale: Locale) -> Bool {
        entry(for: locale) != nil
    }

    public mutating func store(
        requested: Locale,
        resolved: Locale,
        sampleRate: Double,
        channelCount: UInt32
    ) {
        let entry = Entry(
            requestedIdentifier: Self.identifier(requested),
            resolvedIdentifier: Self.identifier(resolved),
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        entriesByRequested[entry.requestedIdentifier] = entry
        entriesByResolved[entry.resolvedIdentifier] = entry
    }

    public mutating func removeAll() {
        entriesByRequested.removeAll()
        entriesByResolved.removeAll()
    }

    public static func identifier(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
    }
}
