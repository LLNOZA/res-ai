import XCTest
@testable import ResAICore

final class HotKeyRecoveryCoordinatorTests: XCTestCase {
    private var coordinator: HotKeyRecoveryCoordinator {
        HotKeyRecoveryCoordinator(staleAfter: 2, externalEventWindow: 2)
    }

    private func slot(
        _ name: String,
        registered: Bool = true,
        enabled: Bool = true,
        age: TimeInterval? = 0
    ) -> HotKeySlotHealth {
        HotKeySlotHealth(
            name: name,
            isRegistered: registered,
            isEnabled: enabled,
            secondsSinceEvent: age
        )
    }

    func testHealthyIdleSlotsAreNotRecreatedOnTimerTicks() {
        let actions = coordinator.actions(
            slots: [slot("rewrite", age: 60), slot("voice", age: 60)],
            secureInputActive: false,
            permissionAvailable: true,
            secondsSinceExternalEvent: nil
        )

        XCTAssertTrue(actions.isEmpty)
    }

    func testDisabledTapGetsRepairWithoutRecreatingHealthySlots() {
        let actions = coordinator.actions(
            slots: [slot("rewrite", enabled: false, age: 60), slot("voice", age: 60)],
            secureInputActive: false,
            permissionAvailable: true,
            secondsSinceExternalEvent: nil
        )

        XCTAssertEqual(actions, [.repairDisabled(slot: "rewrite")])
    }

    func testEnabledTapIsRecreatedOnlyWhenIndependentUserEventIsRecent() {
        let stale = slot("voice", age: 3)

        XCTAssertEqual(
            coordinator.actions(
                slots: [stale],
                secureInputActive: false,
                permissionAvailable: true,
                secondsSinceExternalEvent: 1
            ),
            [.recreateStale(slot: "voice")]
        )
        XCTAssertTrue(
            coordinator.actions(
                slots: [stale],
                secureInputActive: false,
                permissionAvailable: true,
                secondsSinceExternalEvent: 10
            ).isEmpty
        )
    }

    func testMissingSlotRequestsRegistrationAndBlockedStatesDoNothing() {
        let missing = [slot("rewrite", registered: false), slot("voice")]

        XCTAssertEqual(
            coordinator.actions(
                slots: missing,
                secureInputActive: false,
                permissionAvailable: true,
                secondsSinceExternalEvent: 0
            ),
            [.registerMissing]
        )
        XCTAssertTrue(
            coordinator.actions(
                slots: missing,
                secureInputActive: true,
                permissionAvailable: true,
                secondsSinceExternalEvent: 0
            ).isEmpty
        )
        XCTAssertTrue(
            coordinator.actions(
                slots: missing,
                secureInputActive: false,
                permissionAvailable: false,
                secondsSinceExternalEvent: 0
            ).isEmpty
        )
    }
}
