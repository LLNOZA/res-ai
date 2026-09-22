import XCTest
@testable import ResAICore

@MainActor
final class FormFillPlannerTests: XCTestCase {
    func testLocalPlannerFillsKnownProfileFields() async {
        let planner = LocalFormFillPlanner()
        let request = FormFillRequest(
            appInfo: AppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 1),
            fields: [
                FormFieldSnapshot(index: 0, label: "お名前"),
                FormFieldSnapshot(index: 1, label: "会社名"),
                FormFieldSnapshot(index: 2, label: "メールアドレス"),
                FormFieldSnapshot(index: 3, label: "導入目的"),
                FormFieldSnapshot(index: 4, label: "Mailing Address")
            ],
            userProfile: UserProfile(
                displayName: "Example User",
                companyName: "Sample Organization",
                email: "user@example.test",
                address: "Sample City 1-2-3",
                formFillNotes: "AI返信作成の業務効率化に関心があります"
            )
        )

        let suggestions = await planner.plan(request)
        let values = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.fieldIndex, $0.value) })

        XCTAssertEqual(values[0], "Example User")
        XCTAssertEqual(values[1], "Sample Organization")
        XCTAssertEqual(values[2], "user@example.test")
        XCTAssertEqual(values[3], "AI返信作成の業務効率化に関心があります")
        XCTAssertEqual(values[4], "Sample City 1-2-3")
    }

    func testLocalPlannerSkipsSensitiveAndAlreadyFilledFields() async {
        let planner = LocalFormFillPlanner()
        let request = FormFillRequest(
            appInfo: AppInfo(name: "Chrome", bundleIdentifier: "com.google.Chrome", processIdentifier: 1),
            fields: [
                FormFieldSnapshot(index: 0, label: "パスワード"),
                FormFieldSnapshot(index: 1, label: "メール", currentValue: "already@example.com"),
                FormFieldSnapshot(index: 2, label: "電話番号"),
                FormFieldSnapshot(index: 3, label: "認証コード"),
                FormFieldSnapshot(index: 4, label: "利用規約に同意")
            ],
            userProfile: UserProfile(
                email: "user@example.test",
                phone: "000-0000-0000"
            )
        )

        let suggestions = await planner.plan(request)

        XCTAssertEqual(suggestions.map(\.fieldIndex), [2])
        XCTAssertEqual(suggestions.first?.value, "000-0000-0000")
    }
}
