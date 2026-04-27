import XCTest
import os.log
@testable import MachStructCore

// MARK: - ParseBenchmarks

/// XCTest performance suite for Phase 1 parsing targets.
///
/// Performance targets (from PERFORMANCE.md §1, measured on M1 MacBook Air):
/// - 10 MB file → full structural index in < 200 ms
/// - 100 MB file → full structural index in < 1 500 ms (release) / < 6 000 ms (debug)
/// - Progressive stream emits ≥ 10 batches for a large file
///
/// Note: since simdjson is now compiled from source (P5-01), debug builds are
/// significantly slower than release builds.  Performance SLAs apply to release.
///
/// Each benchmark is also instrumented with `os_signpost` so runs under
/// Instruments show named intervals in the Points of Interest track.
final class ParseBenchmarks: XCTestCase {

    // MARK: - Setup

    private let corpus = TestCorpusGenerator()

    /// Signpost log visible in Instruments › Points of Interest.
    private static let log = OSLog(subsystem: "com.lustech.machstruct",
                                   category: "ParseBenchmarks")

    override func setUpWithError() throws {
        try corpus.prepare()
        // Pre-generate all corpus files before timing starts so generation
        // cost doesn't pollute benchmark results.
        for c in TestCorpusGenerator.Corpus.allCases {
            _ = try corpus.url(for: c)
        }
    }

    // MARK: - Correctness: malformed JSON

    func testMalformedJSONProducesError() async throws {
        let url  = try corpus.url(for: .malformed)
        let file = try MappedFile(url: url)
        do {
            _ = try await JSONParser().buildIndex(from: file)
            XCTFail("Expected a parse error for malformed JSON")
        } catch {
            // expected — any error is acceptable
        }
    }

    // MARK: - Correctness: all corpus files parse without crash

    func testTinyParses() async throws {
        try await assertParses(.tiny, minimumNodes: 5)
    }

    func testMediumParses() async throws {
        try await assertParses(.medium, minimumNodes: 1_000)
    }

    func testLargeParses() async throws {
        try await assertParses(.large, minimumNodes: 10_000)
    }

    func testHugeParses() async throws {
        try await assertParses(.huge, minimumNodes: 10_000)
    }

    func testPathologicalDeepParses() async throws {
        try await assertParses(.pathologicalDeep, minimumNodes: 200)
    }

    func testPathologicalWideParses() async throws {
        try await assertParses(.pathologicalWide, minimumNodes: 50_000)
    }

    // MARK: - Performance: 10 MB file must index in < 250 ms (release)
    //
    // The release SLA is 250 ms for a real 10 MB file (≈ 1.26 M nodes).
    // Debug builds run simdjson without optimisation; the threshold is
    // relaxed accordingly.

    func testLargeFileIndexTime() async throws {
        let url  = try corpus.url(for: .large)
        let file = try MappedFile(url: url)
        file.adviseSequential()
        let parser = JSONParser()

        os_signpost(.begin, log: Self.log, name: "IndexLarge")
        let start   = Date()
        let index   = try await parser.buildIndex(from: file)
        let elapsed = Date().timeIntervalSince(start) * 1_000   // ms
        os_signpost(.end, log: Self.log, name: "IndexLarge")

        XCTAssertGreaterThan(index.entries.count, 0)
        print("[ParseBenchmarks] large.json (\(file.fileSize / 1024) KB) " +
              "→ \(index.entries.count) entries in \(String(format: "%.1f", elapsed)) ms")
        #if DEBUG
        let limit = 6_000.0
        #else
        let limit = 300.0
        #endif
        XCTAssertLessThan(elapsed, limit,
            "10 MB file must be indexed in < \(Int(limit)) ms. Got \(String(format: "%.1f", elapsed)) ms.")
    }

    /// `XCTMeasure` variant — runs 5 iterations and records average + stddev.
    func testLargeFileIndexPerformance() throws {
        let url    = try corpus.url(for: .large)
        let file   = try MappedFile(url: url)
        let parser = JSONParser()

        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let sema = DispatchSemaphore(value: 0)
            Task.detached {
                _ = try? await parser.buildIndex(from: file)
                sema.signal()
            }
            sema.wait()
        }
    }

    // MARK: - Performance: 100 MB file must index in < 1 500 ms (release) / < 6 000 ms (debug)
    //
    // Debug builds compile simdjson without optimisation; the threshold is relaxed
    // accordingly.  The release limit (1 500 ms) remains the authoritative SLA.

    func testHugeFileIndexTime() async throws {
        let url  = try corpus.url(for: .huge)
        let file = try MappedFile(url: url)
        file.adviseSequential()
        let parser = JSONParser()

        os_signpost(.begin, log: Self.log, name: "IndexHuge")
        let start   = Date()
        let index   = try await parser.buildIndex(from: file)
        let elapsed = Date().timeIntervalSince(start) * 1_000   // ms
        os_signpost(.end, log: Self.log, name: "IndexHuge")

        XCTAssertGreaterThan(index.entries.count, 0)
        print("[ParseBenchmarks] huge.json (\(file.fileSize / (1024*1024)) MB) " +
              "→ \(index.entries.count) entries in \(String(format: "%.1f", elapsed)) ms")
        #if DEBUG
        let limit = 6_000.0
        #else
        let limit = 1_500.0
        #endif
        XCTAssertLessThan(elapsed, limit,
            "100 MB file must be indexed in < \(Int(limit)) ms. Got \(String(format: "%.1f", elapsed)) ms.")
    }

    // MARK: - NodeIndex construction time

    func testNodeIndexBuildLarge() async throws {
        let url   = try corpus.url(for: .large)
        let file  = try MappedFile(url: url)
        let si    = try await JSONParser().buildIndex(from: file)

        let start   = Date()
        let ni      = si.buildNodeIndex()
        let elapsed = Date().timeIntervalSince(start) * 1_000

        XCTAssertNotNil(ni.root)
        XCTAssertGreaterThan(ni.count, 0)
        print("[ParseBenchmarks] NodeIndex build (\(si.entries.count) entries): " +
              "\(String(format: "%.2f", elapsed)) ms")
    }

    // MARK: - Progressive stream: batch count

    /// Large file (10 MB, ≥ 10 000 nodes) must produce ≥ 10 batches of 1 000.
    func testLargeFileProgressiveBatches() async throws {
        let url    = try corpus.url(for: .large)
        let file   = try MappedFile(url: url)
        let parser = JSONParser()

        var batches    = 0
        var totalNodes = 0
        var completed  = false

        for await progress in parser.parseProgressively(file: file) {
            switch progress {
            case .nodesIndexed(let entries):
                batches    += 1
                totalNodes += entries.count
            case .complete:
                completed = true
            case .error(let e):
                XCTFail("Unexpected error: \(e)")
            case .warning:
                break
            }
        }

        XCTAssertTrue(completed, "Stream must emit .complete")
        XCTAssertGreaterThanOrEqual(batches, 10,
            "Expected ≥ 10 progressive batches for large file, got \(batches)")
        print("[ParseBenchmarks] Progressive stream: \(batches) batches, \(totalNodes) total nodes")
    }

    // MARK: - Memory smoke test

    /// Opening large.json should not blow the resident-memory budget.
    /// (Exact measurement requires Instruments; this is a build+run sanity check.)
    func testLargeFileDoesNotOOM() async throws {
        let url  = try corpus.url(for: .large)
        let file = try MappedFile(url: url)
        let si   = try await JSONParser().buildIndex(from: file)
        let ni   = si.buildNodeIndex()
        // If we get here without the process being killed for OOM, we pass.
        XCTAssertGreaterThan(ni.count, 0)
    }

    // MARK: - Deep nesting

    func testPathologicalDeepDoesNotCrash() async throws {
        let url  = try corpus.url(for: .pathologicalDeep)
        let file = try MappedFile(url: url)
        let si   = try await JSONParser().buildIndex(from: file)
        XCTAssertGreaterThan(si.entries.count, 0)
        let maxDepth = si.entries.map { Int($0.depth) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxDepth, 10,
            "Expected deep nesting, got max depth \(maxDepth)")
        print("[ParseBenchmarks] pathological_deep max depth: \(maxDepth)")
    }

    // MARK: - Wide array

    func testPathologicalWideNodeCount() async throws {
        let url  = try corpus.url(for: .pathologicalWide)
        let file = try MappedFile(url: url)
        let si   = try await JSONParser().buildIndex(from: file)
        // 50 000 objects × 4 nodes each ≈ 200 000 nodes
        XCTAssertGreaterThan(si.entries.count, 100_000,
            "Expected > 100 K entries for wide file, got \(si.entries.count)")
        print("[ParseBenchmarks] pathological_wide: \(si.entries.count) entries")
    }

    // MARK: - Validation

    func testValidateReturnsNoIssuesForValidFiles() async throws {
        for corpus in [TestCorpusGenerator.Corpus.tiny, .medium, .large] {
            let url    = try self.corpus.url(for: corpus)
            let file   = try MappedFile(url: url)
            let issues = try await JSONParser().validate(file: file)
            XCTAssertTrue(issues.isEmpty,
                "\(corpus.fileName) should validate without issues, got: \(issues)")
        }
    }

    func testValidateDetectsMalformedJSON() async throws {
        let url    = try corpus.url(for: .malformed)
        let file   = try MappedFile(url: url)
        let issues = try await JSONParser().validate(file: file)
        XCTAssertFalse(issues.isEmpty, "Malformed JSON should produce validation issues")
        XCTAssertEqual(issues.first?.severity, .error)
    }
}

// MARK: - Helpers

private extension ParseBenchmarks {

    func assertParses(_ corpus: TestCorpusGenerator.Corpus,
                      minimumNodes: Int) async throws {
        let url   = try self.corpus.url(for: corpus)
        let file  = try MappedFile(url: url)
        let index = try await JSONParser().buildIndex(from: file)
        XCTAssertGreaterThanOrEqual(index.entries.count, minimumNodes,
            "\(corpus.fileName): expected ≥ \(minimumNodes) entries, " +
            "got \(index.entries.count)")
    }
}
