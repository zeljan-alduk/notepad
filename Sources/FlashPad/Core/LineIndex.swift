import Foundation

/// A sparse index of line-start byte offsets, built on a background thread.
///
/// Storing every line offset for a multi-GB file would cost gigabytes, so we
/// keep a checkpoint only every `stride` lines. To locate an arbitrary line we
/// jump to the nearest checkpoint and scan forward with `memchr` — fast because
/// the gap is bounded and the bytes are already paged in.
final class LineIndex {
    /// One checkpoint per `stride` lines.
    let stride = 4096

    private let lock = NSLock()
    private var checkpoints: [Int] = [0]   // checkpoints[k] = byte offset of line k*stride
    private var _lineCount: Int = 1        // an empty file still has one (empty) line
    private var _finished = false
    private unowned let file: MappedFile

    /// Called on the main thread as indexing makes progress / completes.
    var onProgress: (() -> Void)?

    init(file: MappedFile) {
        self.file = file
    }

    var lineCount: Int { lock.withLock { _lineCount } }
    var isFinished: Bool { lock.withLock { _finished } }
    /// Total number of '\n' bytes in the original file.
    var totalLineFeeds: Int { lock.withLock { _lineCount - 1 } }

    func build() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scan()
        }
    }

    /// Builds the index on the calling thread. Used by tests and when an edit
    /// needs an authoritative index before the background scan would finish.
    func buildSynchronously() { scan() }

    private func scan() {
        let n = file.count
        if n == 0 { finish(lineCount: 1); return }

        var newlines = 0
        var cps: [Int] = [0]
        var lastPublishedNewlines = 0

        // Scan in chunks via pread so the whole file never enters our RSS; only
        // the small reusable buffer below is resident.
        let chunkSize = 4 << 20
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var fileOffset = 0

        while fileOffset < n {
            let want = min(chunkSize, n - fileOffset)
            let got = buffer.withUnsafeMutableBytes {
                file.readChunk(into: $0.baseAddress!, offset: fileOffset, count: want)
            }
            if got <= 0 { break }

            buffer.withUnsafeBytes { raw in
                let bptr = raw.baseAddress!
                var j = 0
                while j < got {
                    guard let found = memchr(bptr + j, 0x0A, got - j) else { break }
                    let local = bptr.distance(to: found)
                    newlines += 1
                    if newlines % stride == 0 { cps.append(fileOffset + local + 1) }
                    j = local + 1
                }
            }
            fileOffset += got

            if newlines - lastPublishedNewlines >= 1_000_000 {
                lastPublishedNewlines = newlines
                publish(checkpoints: cps, lineCount: newlines + 1, finished: false)
            }
        }
        publish(checkpoints: cps, lineCount: newlines + 1, finished: true)
    }

    private func publish(checkpoints cps: [Int], lineCount: Int, finished: Bool) {
        lock.withLock {
            checkpoints = cps
            _lineCount = lineCount
            _finished = finished
        }
        DispatchQueue.main.async { [weak self] in self?.onProgress?() }
    }

    private func finish(lineCount: Int) {
        publish(checkpoints: [0], lineCount: lineCount, finished: true)
    }

    /// Byte offset where `line` (0-based) begins. Clamps to known data while the
    /// background scan is still in flight.
    func byteOffset(forLine line: Int) -> Int {
        let target = max(0, line)
        let (startLine, startOffset) = lock.withLock { () -> (Int, Int) in
            let c = min(target / stride, checkpoints.count - 1)
            return (c * stride, checkpoints[c])
        }
        var ln = startLine
        var off = startOffset
        let n = file.count
        let base = file.rawBase
        while ln < target, off < n {
            guard let found = memchr(base + off, 0x0A, n - off) else { return n }
            off = base.distance(to: found) + 1
            ln += 1
        }
        return off
    }

    /// 0-based line number that `offset` falls on, i.e. the count of '\n' bytes
    /// strictly before `offset`. Cost is bounded by one checkpoint stride.
    func lineOf(offset: Int) -> Int {
        let n = file.count
        let target = min(max(0, offset), n)
        let (baseLine, baseOffset) = lock.withLock { () -> (Int, Int) in
            // Largest checkpoint whose offset is <= target.
            var lo = 0, hi = checkpoints.count - 1, best = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if checkpoints[mid] <= target { best = mid; lo = mid + 1 }
                else { hi = mid - 1 }
            }
            return (best * stride, checkpoints[best])
        }
        var ln = baseLine
        var off = baseOffset
        let base = file.rawBase
        while off < target {
            guard let found = memchr(base + off, 0x0A, target - off) else { break }
            let p = base.distance(to: found)
            if p >= target { break }
            ln += 1
            off = p + 1
        }
        return ln
    }

    /// Byte offset of the newline (or EOF) ending the line that starts at `start`.
    func lineEnd(fromStart start: Int) -> Int {
        let n = file.count
        guard start < n else { return n }
        if let found = memchr(file.rawBase + start, 0x0A, n - start) {
            return file.rawBase.distance(to: found)
        }
        return n
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
