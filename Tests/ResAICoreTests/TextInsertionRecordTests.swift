import CoreFoundation
import XCTest
@testable import ResAICore

final class TextInsertionRecordTests: XCTestCase {
    func testUtf16SubstringASCII() {
        XCTAssertEqual(TextReplacer.utf16Substring("hello world", range: CFRange(location: 6, length: 5)), "world")
        XCTAssertEqual(TextReplacer.utf16Substring("hello", range: CFRange(location: 0, length: 5)), "hello")
        XCTAssertEqual(TextReplacer.utf16Substring("hello", range: CFRange(location: 5, length: 0)), "")
        XCTAssertEqual(TextReplacer.utf16Substring("", range: CFRange(location: 0, length: 0)), "")
    }

    func testUtf16SubstringJapanese() {
        let s = "こんにちは世界"
        XCTAssertEqual(TextReplacer.utf16Substring(s, range: CFRange(location: 0, length: 5)), "こんにちは")
        XCTAssertEqual(TextReplacer.utf16Substring(s, range: CFRange(location: 5, length: 2)), "世界")
    }

    func testUtf16SubstringEmojiSurrogatePair() {
        let s = "hi🌍世界"
        // "hi" = 2, 🌍 = 2 UTF-16 units, "世界" = 2
        XCTAssertEqual(TextReplacer.utf16Substring(s, range: CFRange(location: 2, length: 2)), "🌍")
        XCTAssertEqual(TextReplacer.utf16Substring(s, range: CFRange(location: 4, length: 2)), "世界")
        XCTAssertEqual(TextReplacer.utf16Substring(s, range: CFRange(location: 0, length: 6)), s)
        XCTAssertNil(TextReplacer.utf16Substring(s, range: CFRange(location: 2, length: 1)))
    }

    func testUtf16SubstringOutOfBounds() {
        XCTAssertNil(TextReplacer.utf16Substring("abc", range: CFRange(location: -1, length: 1)))
        XCTAssertNil(TextReplacer.utf16Substring("abc", range: CFRange(location: 0, length: -1)))
        XCTAssertNil(TextReplacer.utf16Substring("abc", range: CFRange(location: 2, length: 2)))
        XCTAssertNil(TextReplacer.utf16Substring("abc", range: CFRange(location: 4, length: 0)))
        XCTAssertNil(TextReplacer.utf16Substring("abc", range: CFRange(location: 0, length: 4)))
    }

    func testNearestOccurrencePrefersCloserThenEarlier() {
        let haystack = "alpha test beta test gamma"

        XCTAssertEqual(location(TextReplacer.nearestOccurrenceRange(of: "test", in: haystack, near: 6)), 6)
        XCTAssertEqual(location(TextReplacer.nearestOccurrenceRange(of: "test", in: haystack, near: 16)), 16)
        XCTAssertEqual(location(TextReplacer.nearestOccurrenceRange(of: "test", in: haystack, near: 11)), 6)
        XCTAssertNil(TextReplacer.nearestOccurrenceRange(of: "missing", in: haystack, near: 0))
        XCTAssertNil(TextReplacer.nearestOccurrenceRange(of: "", in: haystack, near: 0))
    }

    func testUniqueOccurrenceRange() {
        let unique = TextReplacer.uniqueOccurrenceRange(of: "世界", in: "hello 世界")
        XCTAssertEqual(location(unique), 6)
        XCTAssertEqual(length(unique), 2)

        XCTAssertNil(TextReplacer.uniqueOccurrenceRange(of: "test", in: "test and test"))
        XCTAssertNil(TextReplacer.uniqueOccurrenceRange(of: "nope", in: "hello"))
        XCTAssertNil(TextReplacer.uniqueOccurrenceRange(of: "", in: "hello"))
    }

    func testResolvedInsertedRangeUsesPreferredSliceThenNearest() {
        let haystack = "xx hello yy hello zz"

        XCTAssertEqual(location(TextReplacer.resolvedInsertedRange(of: "hello", in: haystack, preferredLocation: 3)), 3)
        XCTAssertEqual(location(TextReplacer.resolvedInsertedRange(of: "hello", in: haystack, preferredLocation: 12)), 12)
        XCTAssertNil(TextReplacer.resolvedInsertedRange(of: "hello", in: haystack, preferredLocation: nil))
        XCTAssertEqual(location(TextReplacer.resolvedInsertedRange(of: "yy", in: haystack, preferredLocation: nil)), 9)
    }

    func testRangeForReplacingInsertionRejectsChangedField() {
        XCTAssertNil(
            TextReplacer.rangeForReplacingInsertion(
                insertedText: "hello",
                insertedRange: CFRange(location: 4, length: 5),
                valueAfterInsertion: "abc hello",
                currentValue: "abc hello!"
            )
        )
    }

    func testRangeForReplacingInsertionUsesKnownRangeWhenSliceMatches() {
        let range = TextReplacer.rangeForReplacingInsertion(
            insertedText: "hello",
            insertedRange: CFRange(location: 4, length: 5),
            valueAfterInsertion: "abc hello",
            currentValue: "abc hello"
        )
        XCTAssertEqual(location(range), 4)
        XCTAssertEqual(length(range), 5)
    }

    func testRangeForReplacingInsertionFallsBackToUniqueOccurrence() {
        let range = TextReplacer.rangeForReplacingInsertion(
            insertedText: "hello",
            insertedRange: CFRange(location: 0, length: 5),
            valueAfterInsertion: nil,
            currentValue: "abc hello"
        )
        XCTAssertEqual(location(range), 4)
        XCTAssertEqual(length(range), 5)

        XCTAssertNil(
            TextReplacer.rangeForReplacingInsertion(
                insertedText: "hello",
                insertedRange: nil,
                valueAfterInsertion: nil,
                currentValue: "hello hello"
            )
        )
    }

    func testRangeForReplacingInsertionEmptyInsertedTextNeedsKnownRange() {
        let range = TextReplacer.rangeForReplacingInsertion(
            insertedText: "",
            insertedRange: CFRange(location: 3, length: 0),
            valueAfterInsertion: "abcdef",
            currentValue: "abcdef"
        )
        XCTAssertEqual(location(range), 3)
        XCTAssertEqual(length(range), 0)

        XCTAssertNil(
            TextReplacer.rangeForReplacingInsertion(
                insertedText: "",
                insertedRange: nil,
                valueAfterInsertion: "abcdef",
                currentValue: "abcdef"
            )
        )
    }

    func testOccurrenceRangesSkipOverlappingAdvance() {
        let ranges = TextReplacer.utf16OccurrenceRanges(of: "aa", in: "aaaa")
        XCTAssertEqual(ranges.map { Int($0.location) }, [0, 2])
    }

    private func location(_ range: CFRange?) -> Int? {
        range.map { Int($0.location) }
    }

    private func length(_ range: CFRange?) -> Int? {
        range.map { Int($0.length) }
    }
}
