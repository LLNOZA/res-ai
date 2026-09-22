import XCTest
@testable import ResAICore

final class LogRotationPolicyTests: XCTestCase {
    func testShouldRotateWhenSizeExceedsLimit() {
        XCTAssertFalse(LogRotationPolicy.shouldRotate(size: 5 * 1024 * 1024, limit: 5 * 1024 * 1024))
        XCTAssertTrue(LogRotationPolicy.shouldRotate(size: 5 * 1024 * 1024 + 1, limit: 5 * 1024 * 1024))
        XCTAssertFalse(LogRotationPolicy.shouldRotate(size: 0, limit: 100))
    }

    func testRotateIfNeededRenamesCurrentAndReplacesOlderRotatedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogRotationPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let current = directory.appendingPathComponent("responseai.log")
        let rotated = directory.appendingPathComponent("responseai.1.log")
        try Data("old-rotated".utf8).write(to: rotated)
        try Data(repeating: 0x61, count: 32).write(to: current)

        LogRotationPolicy.rotateIfNeeded(current: current, rotated: rotated, limit: 16)

        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertEqual(try Data(contentsOf: rotated).count, 32)
    }

    func testRotateIfNeededIsNoOpWhenUnderLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogRotationPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let current = directory.appendingPathComponent("responseai.log")
        let rotated = directory.appendingPathComponent("responseai.1.log")
        try Data("keep".utf8).write(to: current)

        LogRotationPolicy.rotateIfNeeded(current: current, rotated: rotated, limit: 1024)

        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "keep")
    }
}
