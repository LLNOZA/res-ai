import CoreGraphics
import XCTest
@testable import ResAICore

final class ContextTextFilterTests: XCTestCase {
    func testKeepsRecentNearbyLinesAboveInput() {
        let filter = ContextTextFilter(maxLines: 2, verticalLookback: 300)
        let inputFrame = CGRect(x: 100, y: 500, width: 600, height: 80)
        let lines = [
            ContextLine(text: "古いメッセージ", frame: CGRect(x: 100, y: 100, width: 600, height: 30)),
            ContextLine(text: "明日でも大丈夫ですか？", frame: CGRect(x: 100, y: 430, width: 600, height: 30)),
            ContextLine(text: "送信", frame: CGRect(x: 680, y: 520, width: 80, height: 30)),
            ContextLine(text: "明日でいいよ", frame: inputFrame)
        ]

        let result = filter.filter(lines: lines, inputFrame: inputFrame, draft: "明日でいいよ")

        XCTAssertEqual(result.map(\.text), ["明日でも大丈夫ですか？"])
    }

    func testDropsCommonBrowserMessengerNoise() {
        let filter = ContextTextFilter(maxLines: 4, verticalLookback: 600, horizontalPadding: 500)
        let inputFrame = CGRect(x: 260, y: 760, width: 520, height: 72)
        let lines = [
            ContextLine(text: "Messenger", frame: CGRect(x: 140, y: 300, width: 120, height: 24)),
            ContextLine(text: "Like", frame: CGRect(x: 250, y: 650, width: 40, height: 20)),
            ContextLine(text: "明日の14時でどうですか？", frame: CGRect(x: 300, y: 690, width: 320, height: 28)),
            ContextLine(text: "いいよ", frame: inputFrame),
            ContextLine(text: "Send", frame: CGRect(x: 820, y: 770, width: 50, height: 26))
        ]

        let result = filter.filter(lines: lines, inputFrame: inputFrame, draft: "いいよ")

        XCTAssertEqual(result.map(\.text), ["明日の14時でどうですか？"])
    }

    func testKeepsOpeningLineWhenOverMaxLines() {
        let filter = ContextTextFilter(maxLines: 2, verticalLookback: 800)
        let inputFrame = CGRect(x: 100, y: 500, width: 600, height: 80)
        let lines = [
            ContextLine(text: "最初の要件です", frame: CGRect(x: 100, y: 120, width: 600, height: 30)),
            ContextLine(text: "途中のやりとり", frame: CGRect(x: 100, y: 280, width: 600, height: 30)),
            ContextLine(text: "直近の確認です", frame: CGRect(x: 100, y: 430, width: 600, height: 30))
        ]

        let result = filter.filter(lines: lines, inputFrame: inputFrame, draft: "")

        XCTAssertEqual(result.map(\.text), ["最初の要件です", "直近の確認です"])
    }
}
