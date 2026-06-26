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

    func build() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scan()
        }
    }

    private func scan() {
        let n = file.count
        if n == 0 { finish(lineCount: 1); return }

        let base = file.rawBase
        var i = 0
        var newlines = 0
        var cps: [Int] = [0]
        var lastPublishedNewlines = 0

        while i < n {
            guard let found = memchr(base + i, 0x0A, n - i) else { break }
            let off = base.distance(to: found)   // byte offset of this '\n'
            newlines += 1
            let lineStart = off + 1              // next line begins after the newline
            if newlines % stride == 0 {
                cps.append(lineStart)
            }
            i = off + 1

            // Publish progress periodically so the view can grow as we scan.
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
