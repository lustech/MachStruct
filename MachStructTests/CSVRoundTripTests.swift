import XCTest
@testable import MachStructCore

/// Saving a CSV document writes CSV back in the file's own layout (#39).
final class CSVRoundTripTests: XCTestCase {

    private func roundTrip(_ csv: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString).csv")
        try Data(csv.utf8).write(to: url)
        let index = try await CSVParser().buildIndex(from: MappedFile(url: url)).buildNodeIndex()
        let data = try CSVDocumentSerializer(index: index).serializeInSourceLayout()
        return String(decoding: data, as: UTF8.self)
    }

    func testHeaderedCSVRoundTripsExactly() async throws {
        let csv = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
        let out = try await roundTrip(csv)
        XCTAssertEqual(out, csv)
    }

    func testDelimiterIsPreserved() async throws {
        let csv = "name;age\nAlice;30\nBob;25\n"
        let out = try await roundTrip(csv)
        XCTAssertEqual(out, csv)
    }

    func testHeaderlessCSVRoundTripsWithoutAddingAHeader() async throws {
        let csv = "1,2,3\n4,5,6\n"
        let out = try await roundTrip(csv)
        XCTAssertEqual(out, csv)
    }

    func testQuotedFieldsRoundTrip() async throws {
        let csv = "name,note\nAlice,\"a, b\"\nBob,\"say \"\"hi\"\"\"\n"
        let out = try await roundTrip(csv)
        XCTAssertEqual(out, csv)
    }

    /// A line break joined into one character with another, or a delimiter
    /// joined to a combining mark, still needs the field quoted: unquoted, it
    /// splits the field when the file is read back (#75).
    func testFieldsWithJoinedLineBreaksOrDelimitersAreQuoted() async throws {
        let csv = "name,note\nAlice,\"line\r\nbreak\"\nBob,\"x,\u{301}y\"\n"
        let out = try await roundTrip(csv)
        XCTAssertEqual(out, csv)
    }

    func testRaggedRowsKeepEveryField() async throws {
        let out = try await roundTrip("a,b,c\n1,2\n3,4,5,6\n")
        XCTAssertEqual(out, "a,b,c,column_4\n1,2,,\n3,4,5,6\n")
    }
}
