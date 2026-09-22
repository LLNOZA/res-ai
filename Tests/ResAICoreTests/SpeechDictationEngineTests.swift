import XCTest
@testable import ResAICore

@MainActor
final class SpeechDictationEngineTests: XCTestCase {
    func testDisplayTextConcatenatesFinalizedAndVolatile() {
        let empty = DictationTranscript()
        XCTAssertEqual(empty.displayText, "")

        let transcript = DictationTranscript(finalizedText: "hello ", volatileText: "world")
        XCTAssertEqual(transcript.displayText, "hello world")
        XCTAssertEqual(transcript.finalizedText, "hello ")
        XCTAssertEqual(transcript.volatileText, "world")
    }

    func testFactoryPicksEngineOnEveryOS() {
        XCTAssertTrue(SpeechDictationEngineFactory.isSupported)
        let engine = SpeechDictationEngineFactory.make()
        if #available(macOS 26.0, *) {
            XCTAssertEqual(SpeechDictationEngineFactory.engineName, "SpeechAnalyzer")
            XCTAssertEqual(engine.engineName, "SpeechAnalyzer")
        } else {
            XCTAssertEqual(SpeechDictationEngineFactory.engineName, "SFSpeechRecognizer")
            XCTAssertEqual(engine.engineName, "SFSpeechRecognizer")
        }
    }

    func testLegacyEngineExposesExpectedNameOnEveryOS() {
        let engine = LegacySpeechRecognizerEngine()
        XCTAssertEqual(engine.engineName, "SFSpeechRecognizer")
        XCTAssertFalse(engine.isRunning)
    }

    func testPreparedLocaleCacheLooksUpByRequestedAndResolvedLocale() {
        var cache = PreparedLocaleCache()
        XCTAssertTrue(cache.isEmpty)

        let requested = Locale(identifier: "ja_JP")
        let resolved = Locale(identifier: "ja")
        XCTAssertNotEqual(
            PreparedLocaleCache.identifier(requested),
            PreparedLocaleCache.identifier(resolved)
        )

        cache.store(requested: requested, resolved: resolved, sampleRate: 16_000, channelCount: 1)

        XCTAssertTrue(cache.isPrepared(for: requested))
        XCTAssertTrue(cache.isPrepared(for: resolved))
        XCTAssertFalse(cache.isPrepared(for: Locale(identifier: "en_US")))

        let byRequested = cache.entry(for: requested)
        XCTAssertEqual(byRequested?.resolvedIdentifier, PreparedLocaleCache.identifier(resolved))
        XCTAssertEqual(byRequested?.sampleRate, 16_000)
        XCTAssertEqual(byRequested?.channelCount, 1)

        let byResolved = cache.entry(for: resolved)
        XCTAssertEqual(byResolved?.sampleRate, 16_000)
        XCTAssertEqual(byResolved?.requestedIdentifier, PreparedLocaleCache.identifier(requested))
    }

    func testPreparedLocaleCacheStoreIsIdempotentPerRequestedLocale() {
        var cache = PreparedLocaleCache()
        let requested = Locale(identifier: "ja_JP")
        let resolved = Locale(identifier: "ja")
        cache.store(requested: requested, resolved: resolved, sampleRate: 16_000, channelCount: 1)
        cache.store(requested: requested, resolved: resolved, sampleRate: 24_000, channelCount: 1)

        XCTAssertEqual(cache.entry(for: requested)?.sampleRate, 24_000)
        XCTAssertEqual(cache.entry(for: resolved)?.sampleRate, 24_000)

        cache.removeAll()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertFalse(cache.isPrepared(for: requested))
    }

    func testVoiceSessionLifecycleRejectsStaleCallbacks() {
        var lifecycle = VoiceSessionLifecycle()
        let first = lifecycle.begin()
        XCTAssertTrue(lifecycle.isCurrent(first))

        let second = lifecycle.begin()
        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertTrue(lifecycle.isCurrent(second))

        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.isCurrent(second))
    }

    func testVoiceLifecycleTimeoutReturnsBeforeCancelledOperationFinishes() async {
        let start = Date()
        let result = await VoiceLifecycleTimeout.run(timeout: .milliseconds(20)) {
            try? await Task.sleep(for: .seconds(1))
            return "late"
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.5)
    }
}
