import XCTest
@testable import XTBKit

final class LogFileTests: XCTestCase {
    /// On a fresh install the log's folder does not exist yet.
    func testCreatesMissingFolderAndAppends() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("XTBBar/log.txt")
        try appendLine("first", to: url)
        try appendLine("second", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\nsecond\n")
    }
}
