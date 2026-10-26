import Foundation

// MARK: - ParseError

/// A file that could not be parsed: what is wrong and where, in the user's
/// terms. Parsers translate their library's error into this, so the message
/// never names simdjson, Foundation, Yams or libxml2, or an error number (#26).
public struct ParseError: Error, LocalizedError, Sendable, Equatable {

    /// What is wrong, e.g. "Badly formed object".
    public let problem: String
    /// 1-based line of the problem, when known.
    public let line: Int?
    /// 1-based column, counted in characters, when known.
    public let column: Int?
    /// The offending line with a `^` under the problem, for monospaced display.
    public let excerpt: String?

    public init(problem: String, line: Int? = nil, column: Int? = nil, excerpt: String? = nil) {
        self.problem = problem
        self.line = line
        self.column = column
        self.excerpt = excerpt
    }

    /// Locate `byteOffset` in `source` (UTF-8).
    public init(problem: String, byteOffset: Int, in source: UnsafeRawBufferPointer) {
        let end = min(max(byteOffset, 0), source.count)
        var line = 1
        var lineStart = 0
        var i = 0
        while i < end {
            if Self.isLineBreak(source, at: i) {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        let column = Self.scalarCount(source, from: lineStart, to: end) + 1
        self.init(problem: problem, line: line, column: column, in: source)
    }

    /// `line` and `column` (both 1-based, column in characters) in `source`.
    public init(problem: String, line: Int, column: Int, in source: UnsafeRawBufferPointer) {
        self.init(problem: problem, line: line, column: column,
                  excerpt: Self.excerpt(line: line, column: column, in: source))
    }

    public var errorDescription: String? {
        var sentence = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = sentence.first { sentence = first.uppercased() + sentence.dropFirst() }
        if !sentence.hasSuffix(".") { sentence += "." }
        guard let line, let column else { return sentence }
        return "Line \(line), column \(column): \(sentence)"
    }

    // MARK: - Excerpt

    /// Longest stretch of a line shown; minified files are one huge line.
    private static let excerptWidth = 80

    private static func excerpt(line: Int, column: Int,
                                in source: UnsafeRawBufferPointer) -> String? {
        var start = 0
        var current = 1
        var i = 0
        while current < line, i < source.count {
            if isLineBreak(source, at: i) {
                current += 1
                start = i + 1
            }
            i += 1
        }
        guard current == line else { return nil }
        var end = start
        while end < source.count, source[end] != 0x0A, source[end] != 0x0D { end += 1 }

        // Tabs would push the caret out of line with the text.
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: source[start..<end]),
                          as: UTF8.self)
            .replacingOccurrences(of: "\t", with: " ")
        var scalars = Array(text.unicodeScalars)
        var caret = min(max(column - 1, 0), scalars.count)

        if scalars.count > excerptWidth {
            let from = min(max(caret - excerptWidth / 2, 0), scalars.count - excerptWidth)
            let to = from + excerptWidth
            var window = Array(scalars[from..<to])
            caret -= from
            if from > 0 { window.insert("…", at: 0); caret += 1 }
            if to < scalars.count { window.append("…") }
            scalars = window
        }

        var shown = String.UnicodeScalarView()
        shown.append(contentsOf: scalars)
        return String(shown) + "\n" + String(repeating: " ", count: caret) + "^"
    }

    // MARK: - Byte helpers

    /// LF, CR, and the CR of a CRLF pair all end a line; CRLF counts once.
    private static func isLineBreak(_ source: UnsafeRawBufferPointer, at i: Int) -> Bool {
        source[i] == 0x0A || (source[i] == 0x0D && (i + 1 == source.count || source[i + 1] != 0x0A))
    }

    private static func scalarCount(_ source: UnsafeRawBufferPointer, from: Int, to: Int) -> Int {
        var count = 0
        for i in from..<to where source[i] & 0xC0 != 0x80 { count += 1 }
        return count
    }
}
