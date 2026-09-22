import XCTest
@testable import ResAICore

final class VoiceActivationStateMachineTests: XCTestCase {
    func testHoldThenReleaseConfirms() {
        var machine = VoiceActivationStateMachine()

        XCTAssertEqual(machine.handle(.keyDown(at: 1.0)), .startListening)
        XCTAssertEqual(machine.state, .holding(since: 1.0))

        XCTAssertEqual(machine.handle(.keyUp(at: 1.25)), .confirm)
        XCTAssertEqual(machine.state, .finishing)
    }

    func testHoldExactlyAtThresholdConfirms() {
        var machine = VoiceActivationStateMachine()
        XCTAssertEqual(machine.handle(.keyDown(at: 0)), .startListening)
        XCTAssertEqual(machine.handle(.keyUp(at: 0.25)), .confirm)
        XCTAssertEqual(machine.state, .finishing)
    }

    func testTapEntersToggleThenNextPressConfirms() {
        var machine = VoiceActivationStateMachine()

        XCTAssertEqual(machine.handle(.keyDown(at: 0)), .startListening)
        XCTAssertEqual(machine.handle(.keyUp(at: 0.24)), .none)
        XCTAssertEqual(machine.state, .toggled)

        XCTAssertEqual(machine.handle(.keyUp(at: 0.5)), .none)
        XCTAssertEqual(machine.state, .toggled)

        XCTAssertEqual(machine.handle(.keyDown(at: 1.0)), .confirm)
        XCTAssertEqual(machine.state, .finishing)
    }

    func testEventsDuringFinishingAreIgnoredUntilFinished() {
        var machine = VoiceActivationStateMachine()
        XCTAssertEqual(machine.handle(.keyDown(at: 0)), .startListening)
        XCTAssertEqual(machine.handle(.keyUp(at: 1)), .confirm)

        XCTAssertEqual(machine.handle(.keyDown(at: 2)), .none)
        XCTAssertEqual(machine.handle(.keyUp(at: 3)), .none)
        XCTAssertEqual(machine.handle(.finished), .none)
        XCTAssertEqual(machine.state, .idle)

        XCTAssertEqual(machine.handle(.keyDown(at: 4)), .startListening)
        XCTAssertEqual(machine.state, .holding(since: 4))
    }

    func testToggleOnlyIgnoresKeyUpAndConfirmsOnSecondPress() {
        var machine = VoiceActivationStateMachine()

        XCTAssertEqual(machine.handle(.keyDown(at: 0), mode: .toggleOnly), .startListening)
        XCTAssertEqual(machine.handle(.keyUp(at: 0.1), mode: .toggleOnly), .none)
        XCTAssertEqual(machine.state, .holding(since: 0))
        XCTAssertEqual(machine.handle(.keyUp(at: 2.0), mode: .toggleOnly), .none)
        XCTAssertEqual(machine.state, .holding(since: 0))

        XCTAssertEqual(machine.handle(.keyDown(at: 2.1), mode: .toggleOnly), .confirm)
        XCTAssertEqual(machine.state, .finishing)
        XCTAssertEqual(machine.handle(.keyUp(at: 2.2), mode: .toggleOnly), .none)
        XCTAssertEqual(machine.handle(.finished, mode: .toggleOnly), .none)
        XCTAssertEqual(machine.state, .idle)
    }

    func testHoldOrTapStillConfirmsOnLongKeyUp() {
        var machine = VoiceActivationStateMachine()
        XCTAssertEqual(machine.handle(.keyDown(at: 0), mode: .holdOrTap), .startListening)
        XCTAssertEqual(machine.handle(.keyUp(at: 1), mode: .holdOrTap), .confirm)
        XCTAssertEqual(machine.state, .finishing)
    }
}
