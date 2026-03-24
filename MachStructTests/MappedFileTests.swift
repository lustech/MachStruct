import XCTest
@testable import MachStructCore

final class MappedFileTests: XCTestCase {

    // MARK: - Helpers

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func removeTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Basic open

    func testOpenFile() throws {
        let url = try writeTempFile("Hello, MachStruct!")
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        XCTAssertEqual(mapped.fileSize, UInt64("Hello, MachStruct!".utf8.count))
    }

    // MARK: - Slice

    func testSliceReturnsCorrectBytes() throws {
        let content = "ABCDEFGHIJ"
        let url = try writeTempFile(content)
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        let raw = try mapped.slice(offset: 2, length: 4)
        let str = String(bytes: raw, encoding: .utf8)
        XCTAssertEqual(str, "CDEF")
    }

    func testSliceFullFile() throws {
        let content = "Hello"
        let url = try writeTempFile(content)
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        let raw = try mapped.slice(offset: 0, length: UInt32(mapped.fileSize))
        XCTAssertEqual(Array(raw), Array(content.utf8))
    }

    func testDataCopy() throws {
        let content = "MachStruct"
        let url = try writeTempFile(content)
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        let d = try mapped.data(offset: 0, length: UInt32(mapped.fileSize))
        XCTAssertEqual(d, content.data(using: .utf8))
    }

    // MARK: - Slice bounds

    func testSliceOutOfBoundsThrows() throws {
        let url = try writeTempFile("short")
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        XCTAssertThrowsError(try mapped.slice(offset: mapped.fileSize, length: 1))
    }

    func testSliceExactlyAtEnd() throws {
        let url = try writeTempFile("AB")
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        // offset=1, length=1 → reads byte at index 1 — valid
        let raw = try mapped.slice(offset: 1, length: 1)
        XCTAssertEqual(raw.first, UInt8(ascii: "B"))
    }

    // MARK: - Error cases

    func testFileNotFoundThrows() {
        let bad = URL(fileURLWithPath: "/this/does/not/exist/file.json")
        XCTAssertThrowsError(try MappedFile(url: bad)) { error in
            if case MappedFile.MappingError.fileNotFound = error { return }
            XCTFail("Expected .fileNotFound, got \(error)")
        }
    }

    // MARK: - madvise (smoke tests — these calls must not crash)

    func testAdviseDoesNotCrash() throws {
        let url = try writeTempFile("{}")
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        mapped.adviseSequential()
        mapped.adviseRandom()
        mapped.adviseSequential()
    }

    // MARK: - Large file / memory footprint

    func testLargeFileMappedWithoutFullLoad() throws {
        // Write a ~2 MB file and map it; reading only a tiny slice should not
        // load the entire file into resident memory (validated manually in Instruments).
        let chunk = String(repeating: "x", count: 1024)
        let content = String(repeating: chunk, count: 2048) // 2 MB
        let url = try writeTempFile(content)
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        XCTAssertGreaterThan(mapped.fileSize, 1_000_000)

        // Read only the first 64 bytes
        let raw = try mapped.slice(offset: 0, length: 64)
        XCTAssertEqual(raw.count, 64)
        XCTAssertEqual(raw.first, UInt8(ascii: "x"))
    }

    // MARK: - rawPointer is stable

    func testRawPointerPointsToMappedContent() throws {
        let content = "TEST"
        let url = try writeTempFile(content)
        defer { removeTempFile(url) }

        let mapped = try MappedFile(url: url)
        let ptr = mapped.rawPointer
        let first = ptr.load(as: UInt8.self)
        XCTAssertEqual(first, UInt8(ascii: "T"))
    }
}
