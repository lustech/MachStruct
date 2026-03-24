import Foundation
import Darwin

/// Memory-mapped read-only view of a file.
///
/// Uses `mmap(MAP_PRIVATE | MAP_FILE | MAP_NORESERVE)` for zero-copy access.
/// The OS pages data in on demand — a 100 MB file uses only the resident pages
/// that have actually been touched.
///
/// madvise strategy (per PARSING-ENGINE.md §3):
/// - After open: `MADV_SEQUENTIAL` (structural indexing scans front-to-back)
/// - Phase 2:    `MADV_RANDOM`     (value parsing jumps to arbitrary offsets)
public final class MappedFile: @unchecked Sendable {

    public let url: URL
    public let fileSize: UInt64

    private let fd: Int32
    private let base: UnsafeRawPointer

    // MARK: - Errors

    public enum MappingError: Error, CustomStringConvertible {
        case fileNotFound(URL)
        case permissionDenied(URL)
        case emptyFile(URL)
        case mmapFailed(errno: Int32)
        case sliceOutOfRange(offset: UInt64, length: UInt32, fileSize: UInt64)

        public var description: String {
            switch self {
            case .fileNotFound(let u):    return "File not found: \(u.path)"
            case .permissionDenied(let u): return "Permission denied: \(u.path)"
            case .emptyFile(let u):        return "Empty file: \(u.path)"
            case .mmapFailed(let e):       return "mmap failed: errno \(e)"
            case .sliceOutOfRange(let o, let l, let s):
                return "Slice [\(o)..<\(o+UInt64(l))] out of range (fileSize=\(s))"
            }
        }
    }

    // MARK: - Init / deinit

    public init(url: URL) throws {
        let path = url.path

        let rawFd = open(path, O_RDONLY)
        guard rawFd >= 0 else {
            switch errno {
            case ENOENT:  throw MappingError.fileNotFound(url)
            case EACCES:  throw MappingError.permissionDenied(url)
            default:      throw MappingError.mmapFailed(errno: errno)
            }
        }

        var st = stat()
        guard fstat(rawFd, &st) == 0 else {
            let e = errno; close(rawFd)
            throw MappingError.mmapFailed(errno: e)
        }

        let size = UInt64(st.st_size)
        guard size > 0 else {
            close(rawFd)
            throw MappingError.emptyFile(url)
        }

        // MAP_NORESERVE: don't reserve swap space up front
        let rawPtr = mmap(nil, Int(size),
                          PROT_READ,
                          MAP_PRIVATE | MAP_FILE | MAP_NORESERVE,
                          rawFd, 0)
        // MAP_FAILED == (void*)-1
        let mapFailed = UnsafeMutableRawPointer(bitPattern: Int(-1))
        guard let ptr = rawPtr, ptr != mapFailed else {
            let e = errno; close(rawFd)
            throw MappingError.mmapFailed(errno: e)
        }

        self.url      = url
        self.fileSize = size
        self.fd       = rawFd
        self.base     = UnsafeRawPointer(ptr)

        // Initial hint: sequential scan for structural indexing (Phase 1)
        madvise(ptr, Int(size), MADV_SEQUENTIAL)
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), Int(fileSize))
        close(fd)
    }

    // MARK: - madvise hints

    /// Switch to sequential read hint.
    /// Call before structural indexing (Phase 1 — front-to-back scan).
    public func adviseSequential() {
        madvise(UnsafeMutableRawPointer(mutating: base), Int(fileSize), MADV_SEQUENTIAL)
    }

    /// Switch to random read hint.
    /// Call before value parsing (Phase 2 — arbitrary offset jumps).
    public func adviseRandom() {
        madvise(UnsafeMutableRawPointer(mutating: base), Int(fileSize), MADV_RANDOM)
    }

    // MARK: - Access

    /// Zero-copy pointer into the mapped region.
    ///
    /// - Warning: Valid only while this `MappedFile` is alive. Never escape it.
    public func slice(offset: UInt64, length: UInt32) throws -> UnsafeRawBufferPointer {
        guard offset + UInt64(length) <= fileSize else {
            throw MappingError.sliceOutOfRange(offset: offset, length: length,
                                               fileSize: fileSize)
        }
        return UnsafeRawBufferPointer(start: base.advanced(by: Int(offset)),
                                      count: Int(length))
    }

    /// Copy bytes at the given range into `Data`.
    /// Prefer `slice` for hot paths; use this when you need a value-typed copy.
    public func data(offset: UInt64, length: UInt32) throws -> Data {
        Data(try slice(offset: offset, length: length))
    }

    /// Raw pointer to the start of the mapped region.
    /// Used by the simdjson bridge which needs the base address for the whole file.
    /// - Warning: Valid only while this `MappedFile` is alive.
    public var rawPointer: UnsafeRawPointer { base }
}
