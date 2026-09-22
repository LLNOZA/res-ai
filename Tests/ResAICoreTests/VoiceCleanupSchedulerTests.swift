import XCTest
@testable import ResAICore

final class VoiceCleanupSchedulerTests: XCTestCase {
    func testForegroundAllowsKeyboardSwapAndLastCleanup() {
        let id = UUID()
        let decision = VoiceCleanupScheduler.decide(
            cleanupInsertionID: id,
            latestInsertionID: id,
            phase: .idle
        )

        XCTAssertTrue(decision.allowKeyboardSwap)
        XCTAssertTrue(decision.updateLastCleanup)
        XCTAssertFalse(decision.isBackground)
    }

    func testListeningSessionForbidsKeyboardSwapAndIsBackground() {
        let id = UUID()
        let decision = VoiceCleanupScheduler.decide(
            cleanupInsertionID: id,
            latestInsertionID: id,
            phase: .listening
        )

        XCTAssertFalse(decision.allowKeyboardSwap)
        XCTAssertTrue(decision.updateLastCleanup)
        XCTAssertTrue(decision.isBackground)
    }

    func testFinishingSessionForbidsKeyboardSwapAndIsBackground() {
        let id = UUID()
        let decision = VoiceCleanupScheduler.decide(
            cleanupInsertionID: id,
            latestInsertionID: id,
            phase: .finishing
        )

        XCTAssertFalse(decision.allowKeyboardSwap)
        XCTAssertTrue(decision.updateLastCleanup)
        XCTAssertTrue(decision.isBackground)
    }

    func testNewerInsertionForbidsKeyboardSwapAndLastCleanup() {
        let previous = UUID()
        let latest = UUID()
        let decision = VoiceCleanupScheduler.decide(
            cleanupInsertionID: previous,
            latestInsertionID: latest,
            phase: .idle
        )

        XCTAssertFalse(decision.allowKeyboardSwap)
        XCTAssertFalse(decision.updateLastCleanup)
        XCTAssertTrue(decision.isBackground)
    }

    func testNewerInsertionDuringListeningIsBackground() {
        let previous = UUID()
        let latest = UUID()
        let decision = VoiceCleanupScheduler.decide(
            cleanupInsertionID: previous,
            latestInsertionID: latest,
            phase: .listening
        )

        XCTAssertFalse(decision.allowKeyboardSwap)
        XCTAssertFalse(decision.updateLastCleanup)
        XCTAssertTrue(decision.isBackground)
    }

    func testMissingLatestInsertionIsBackground() {
        let decision = VoiceCleanupScheduler.decide(
            cleanupInsertionID: UUID(),
            latestInsertionID: nil,
            phase: .idle
        )

        XCTAssertFalse(decision.allowKeyboardSwap)
        XCTAssertFalse(decision.updateLastCleanup)
        XCTAssertTrue(decision.isBackground)
    }

    func testOverflowCancelsOldestWhenCapExceeded() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        XCTAssertEqual(
            VoiceCleanupScheduler.overflowIDs(pendingOrder: [first, second], adding: third),
            []
        )
        XCTAssertEqual(
            VoiceCleanupScheduler.overflowIDs(pendingOrder: [first, second, third], adding: fourth),
            [first]
        )
    }

    func testOverflowCancelsOldestTwoWhenFourAlreadyPending() {
        let ids = (0..<5).map { _ in UUID() }

        XCTAssertEqual(
            VoiceCleanupScheduler.overflowIDs(pendingOrder: Array(ids.prefix(4)), adding: ids[4]),
            Array(ids.prefix(2))
        )
    }
}
