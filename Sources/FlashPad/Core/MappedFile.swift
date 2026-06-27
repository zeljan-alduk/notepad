import Foundation

/// A read-only, memory-mapped view of a file on disk.
///
/// `mmap` lets the OS page the file in on demand, so opening a multi-gigabyte
/// file costs nothing up front — we only touch the bytes we actually render.
final class MappedFile {
    /// Base pointer to the mapped bytes. Only valid when `count > 0`.
    let rawBase: UnsafeRawPointer
    /// Total number of bytes in the file.
    let count: Int
    let url: URL

    private let fd: Int32
    private let mapLen: Int

    init?(url: URL) {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }

        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        let size = Int(st.st_size)
        self.fd = fd
        self.count = size

        if size == 0 {
            // mmap rejects zero-length mappings; nothing will ever dereference
            // rawBase because every read is guarded by `count`.
            self.rawBase = UnsafeRawPointer(bitPattern: MemoryLayout<UInt8>.alignment)!
            self.mapLen = 0
            return
        }

        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              p != MAP_FAILED else {
            close(fd)
            return nil
        }
        self.rawBase = UnsafeRawPointer(p)
        self.mapLen = size
        // We scan front-to-back while indexing; hint the kernel to read ahead.
        madvise(p, size, MADV_SEQUENTIAL)
    }

    /// A zero-length store, used for brand-new (untitled) documents.
    private init() {
        self.url = URL(fileURLWithPath: "/dev/null")
        self.fd = -1
        self.count = 0
        self.rawBase = UnsafeRawPointer(bitPattern: MemoryLayout<UInt8>.alignment)!
        self.mapLen = 0
    }

    static func empty() -> MappedFile { MappedFile() }

    deinit {
        if mapLen > 0 {
            munmap(UnsafeMutableRawPointer(mutating: rawBase), mapLen)
        }
        close(fd)
    }

    /// Reads bytes via `pread` without touching the mmap. Indexing uses this so
    /// scanning the whole file populates only the (reclaimable, system-wide)
    /// page cache rather than this process's resident set.
    func readChunk(into buffer: UnsafeMutableRawPointer, offset: Int, count: Int) -> Int {
        guard fd >= 0 else { return 0 }
        return pread(fd, buffer, count, off_t(offset))
    }

    @inline(__always)
    func byte(at offset: Int) -> UInt8 {
        rawBase.load(fromByteOffset: offset, as: UInt8.self)
    }

    /// Decodes a byte range as UTF-8 (lossy) for display. Copies only the slice,
    /// so this is cheap when used for the handful of on-screen lines.
    func string(from start: Int, to end: Int) -> String {
        guard end > start, count > 0 else { return "" }
        let buf = UnsafeRawBufferPointer(start: rawBase + start, count: end - start)
        return String(decoding: buf, as: UTF8.self)
    }
}
