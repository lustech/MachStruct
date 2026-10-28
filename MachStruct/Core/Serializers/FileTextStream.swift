import Foundation
import Darwin

// MARK: - FileTextStream

/// Text written straight to a file, a buffer at a time, so a serializer's
/// output for a large document is never held whole: built as a `String` and
/// then copied to `Data`, it peaked at twice its size.
///
/// `TextOutputStream.write` can't throw, so the first error is kept and
/// thrown by `close()`; writing stops at it.
public final class FileTextStream: TextOutputStream {

    private let fd: Int32
    private var buffer: [UInt8] = []
    private let capacity: Int
    private var error: Error?
    private var closed = false

    /// Creates or truncates the file at `url`.
    public init(url: URL, bufferSize: Int = 1 << 20) throws {
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        capacity = bufferSize
        buffer.reserveCapacity(bufferSize)
    }

    deinit {
        if !closed { Darwin.close(fd) }
    }

    public func write(_ string: String) {
        guard error == nil else { return }
        var string = string
        string.withUTF8 { bytes in
            if buffer.count + bytes.count > capacity { flush() }
            if bytes.count >= capacity {
                writeAll(UnsafeRawBufferPointer(bytes))
            } else {
                buffer.append(contentsOf: bytes)
            }
        }
    }

    /// Writes what is buffered and closes the file, throwing the first error
    /// writing met.
    public func close() throws {
        guard !closed else { return }
        flush()
        closed = true
        if Darwin.close(fd) != 0, error == nil {
            error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let error { throw error }
    }

    private func flush() {
        guard !buffer.isEmpty, error == nil else { return }
        buffer.withUnsafeBytes { writeAll($0) }
        buffer.removeAll(keepingCapacity: true)
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count, error == nil {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            } else {
                offset += n
            }
        }
    }
}

// MARK: - Writing a file

extension FileTextStream {

    /// Writes `body`'s output to `url`, replacing it only once all of it is
    /// written, as `Data.write(to:options: .atomic)` does.
    public static func write(to url: URL, _ body: (FileTextStream) throws -> Void) throws {
        let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent(url.lastPathComponent)
        let stream = try FileTextStream(url: file)
        do {
            try body(stream)
            try stream.close()
        } catch {
            try? stream.close()
            throw error
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: url)
        }
    }

    /// `body`'s output as a file wrapper for saving, without holding it in
    /// memory: written to a temporary file that the wrapper maps, which is
    /// removed at once (the mapping keeps its contents).
    public static func fileWrapper(_ body: (FileTextStream) throws -> Void) throws -> FileWrapper {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let stream = try FileTextStream(url: file)
        do {
            try body(stream)
            try stream.close()
        } catch {
            try? stream.close()
            throw error
        }
        return try FileWrapper(url: file, options: .immediate)
    }
}
