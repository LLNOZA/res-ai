import XCTest
@testable import ResAICore

final class InputSafetyPolicyTests: XCTestCase {
    func testSelectionPlanPreservesUnselectedUTF16Text() {
        let original = "前🙂文／選択／後ろ"
        let selected = "選択"
        let start = original.utf16.distance(
            from: original.utf16.startIndex,
            to: original.range(of: selected)!.lowerBound
        )
        let range = CFRange(location: start, length: selected.utf16.count)

        let plan = CapturedTextEditPlan(
            originalValue: original,
            selectedRange: range,
            replacementText: "整形済み"
        )

        XCTAssertEqual(plan?.expectedValue, "前🙂文／整形済み／後ろ")
    }

    func testSelectionPlanAllowsIdenticalSelectionWithoutForcingFallbackInsertion() {
        let original = "前／選択／後ろ"
        let selectedStart = original.utf16.distance(
            from: original.utf16.startIndex,
            to: original.range(of: "選択")!.lowerBound
        )
        let plan = CapturedTextEditPlan(
            originalValue: original,
            selectedRange: CFRange(location: selectedStart, length: "選択".utf16.count),
            replacementText: "選択"
        )

        XCTAssertEqual(plan?.expectedValue, original)
        XCTAssertEqual(plan?.selectedRange?.location, selectedStart)
    }

    func testInvalidSelectionRangeFailsClosed() {
        let plan = CapturedTextEditPlan(
            originalValue: "hello",
            selectedRange: CFRange(location: 1, length: 99),
            replacementText: "replacement"
        )

        XCTAssertNil(plan)
        XCTAssertNil(CapturedTextEditPlan.valueByReplacingSelection(
            originalValue: "🙂",
            selectedRange: CFRange(location: 1, length: 0),
            replacementText: "x"
        ))
    }

    func testSelectionRangeArithmeticOverflowFailsClosed() {
        XCTAssertNil(CapturedTextEditPlan.valueByReplacingSelection(
            originalValue: "hello",
            selectedRange: CFRange(location: Int.max, length: 1),
            replacementText: "x"
        ))
        XCTAssertNil(CapturedTextEditPlan.valueByReplacingSelection(
            originalValue: "hello",
            selectedRange: CFRange(location: 0, length: Int.max),
            replacementText: "x"
        ))
    }

    func testClipboardOwnershipNeverAdoptsAUserCopy() {
        XCTAssertTrue(ClipboardOwnershipPolicy.canAdoptPending(
            pendingWriteChangeCount: 7,
            currentChangeCount: 7
        ))
        XCTAssertFalse(ClipboardOwnershipPolicy.canAdoptPending(
            pendingWriteChangeCount: 7,
            currentChangeCount: 8
        ))
        XCTAssertFalse(ClipboardOwnershipPolicy.shouldRestore(
            expectedWriteChangeCount: 7,
            currentChangeCount: 8
        ))
    }

    func testCopyDuringVerificationIsNotTreatedAsAppOwned() {
        let countAtPublication = 12
        let countWhenRestoreIsScheduled = 13
        XCTAssertFalse(ClipboardOwnershipPolicy.shouldRestore(
            expectedWriteChangeCount: countAtPublication,
            currentChangeCount: countWhenRestoreIsScheduled
        ))
    }

    func testUnknownFormValueIsNeverConsideredEmpty() {
        let unknown = FormFieldSnapshot(
            index: 0,
            label: "Name",
            valueState: .unknown
        )
        XCTAssertFalse(unknown.isEmpty)

        let legacy = try? JSONDecoder().decode(
            FormFieldSnapshot.self,
            from: Data(#"{"index":0,"label":"Name"}"#.utf8)
        )
        XCTAssertEqual(legacy?.valueState, .known)
    }

    func testTraversalBudgetStopsAtEveryIndependentLimit() {
        let budget = AXTraversalBudget(maxDepth: 2, maxNodes: 3, maxMilliseconds: 100)
        XCTAssertTrue(budget.allows(depth: 2, visitedNodes: 2, elapsedMilliseconds: 99))
        XCTAssertFalse(budget.allows(depth: 3, visitedNodes: 2, elapsedMilliseconds: 0))
        XCTAssertFalse(budget.allows(depth: 1, visitedNodes: 3, elapsedMilliseconds: 0))
        XCTAssertFalse(budget.allows(depth: 1, visitedNodes: 2, elapsedMilliseconds: 100))
    }
}
