import XCTest
@testable import ResAICore

final class VoicePillStateTests: XCTestCase {
    func testMapDBFSClampsOutsideMinus50ToMinus10() {
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(-50), 0)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(-10), 1)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(-30), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(-60), 0)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(0), 1)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(-.infinity), 0)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(.nan), 0)
    }

    func testDBFSFromRMS() {
        XCTAssertEqual(AudioLevelSmoother.dbFS(fromRMS: 0), -.infinity)
        XCTAssertEqual(AudioLevelSmoother.dbFS(fromRMS: -1), -.infinity)
        XCTAssertEqual(AudioLevelSmoother.mapDBFS(AudioLevelSmoother.dbFS(fromRMS: 1)), 1)
        // 0.01 RMS → −40 dBFS → (−40 − −50) / 40 = 0.25
        XCTAssertEqual(AudioLevelSmoother.dbFS(fromRMS: 0.01), -40, accuracy: 0.0001)
        XCTAssertEqual(
            AudioLevelSmoother.mapDBFS(AudioLevelSmoother.dbFS(fromRMS: 0.01)),
            0.25,
            accuracy: 0.0001
        )
    }

    func testThrottleAllowsFirstSampleThenDropsUntil30Hz() {
        XCTAssertTrue(AudioLevelSmoother.shouldPublish(lastSent: nil, now: 0))
        XCTAssertFalse(AudioLevelSmoother.shouldPublish(lastSent: 0, now: 0.02))
        XCTAssertFalse(
            AudioLevelSmoother.shouldPublish(lastSent: 0, now: AudioLevelSmoother.minPublishInterval - 0.001)
        )
        XCTAssertTrue(
            AudioLevelSmoother.shouldPublish(lastSent: 0, now: AudioLevelSmoother.minPublishInterval)
        )
        XCTAssertTrue(AudioLevelSmoother.shouldPublish(lastSent: 1.0, now: 1.0 + (1.0 / 30.0)))
    }

    func testExponentialSmoothingAlpha035() {
        var smoother = AudioLevelSmoother()
        XCTAssertEqual(smoother.level, 0)

        let first = smoother.push(1)
        XCTAssertEqual(first, 0.35, accuracy: 0.0001)

        let second = smoother.push(1)
        XCTAssertEqual(second, 0.35 * 1 + 0.65 * 0.35, accuracy: 0.0001)

        var clamped = AudioLevelSmoother()
        XCTAssertEqual(clamped.push(2), 0.35, accuracy: 0.0001)
        XCTAssertEqual(clamped.push(-1), 0.35 * 0 + 0.65 * 0.35, accuracy: 0.0001)
    }
}
