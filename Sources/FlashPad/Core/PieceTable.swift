import Foundation

/// An editable text model that never copies the original file.
///
/// The document is an ordered list of *pieces*, each a slice into one of two
/// buffers: the read-only memory-mapped `original`, or a growing `add` buffer
/// holding everything the user has typed. Editing a 10 GB file therefore costs
/// memory proportional to the edits, not the file.
///
/// Line navigation for original-buffer pieces is delegated to the sparse
/// `LineIndex`, so we never store a per-line table for the whole file.
final class PieceTable {
    enum Source { case original, add }

    struct Piece {
        var source: Source
        var start: Int       // byte offset into its source buffer
        var length: Int      // bytes
        var lineFeeds: Int   // count of '\n' in this slice (cached)
    }

    let original: MappedFile
    let index: LineIndex

    private var add: [UInt8] = []
    /// Absolute positions in `add` just *after* each '\n' (ascending).
    private var addNewlineAfter: [Int] = []
    private(set) var pieces: [Piece] = []

    // Cumulative prefix sums, length == pieces.count + 1.
    private var bytePrefix: [Int] = [0]
    private var linePrefix: [Int] = [0]

    init(original: MappedFile, index: LineIndex, contentStart: Int = 0) {
        self.original = original
        self.index = index
        let len = original.count - contentStart
        if len > 0 {
            // BOM (if any) carries no newline, so the whole-file feed count is
            // also the content feed count.
            pieces = [Piece(source: .original, start: contentStart,
                            length: len, lineFeeds: index.totalLineFeeds)]
        }
        rebuild()
    }

    var byteCount: Int { bytePrefix[bytePrefix.count - 1] }
    /// Lines == total line feeds + 1 (a trailing newline yields an empty last line).
    var lineCount: Int { linePrefix[linePrefix.count - 1] + 1 }

    private func rebuild() {
        bytePrefix = [0]; linePrefix = [0]
        bytePrefix.reserveCapacity(pieces.count + 1)
        linePrefix.reserveCapacity(pieces.count + 1)
        var b = 0, l = 0
        for p in pieces {
            b += p.length; l += p.lineFeeds
            bytePrefix.append(b); linePrefix.append(l)
        }
    }

    // MARK: - Locating

    /// Maps a document byte offset to (piece index, offset within that piece).
    /// For `offset == byteCount` returns (pieces.count, 0).
    private func locate(_ offset: Int) -> (piece: Int, local: Int) {
        let o = min(max(0, offset), byteCount)
        if o == byteCount { return (pieces.count, 0) }
        var lo = 0, hi = pieces.count - 1, hit = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if bytePrefix[mid] <= o { hit = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return (hit, o - bytePrefix[hit])
    }

    // MARK: - Line feed counting / locating within a slice

    private func lineFeeds(source: Source, start: Int, length: Int) -> Int {
        guard length > 0 else { return 0 }
        switch source {
        case .original:
            return index.lineOf(offset: start + length) - index.lineOf(offset: start)
        case .add:
            var count = 0
            var i = start
            let end = start + length
            while i < end { if add[i] == 0x0A { count += 1 }; i += 1 }
            return count
        }
    }

    /// Local offset within a slice just after its `k`-th '\n' (1-based).
    private func offsetAfterNewline(source: Source, start: Int, length: Int, k: Int) -> Int {
        switch source {
        case .original:
            let before = index.lineOf(offset: start)
            let global = index.byteOffset(forLine: before + k)
            return min(max(0, global - start), length)
        case .add:
            // First add-newline strictly after `start`, then step k-1 more.
            var lo = 0, hi = addNewlineAfter.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if addNewlineAfter[mid] <= start { lo = mid + 1 } else { hi = mid }
            }
            let idx = lo + (k - 1)
            guard idx < addNewlineAfter.count else { return length }
            return min(addNewlineAfter[idx] - start, length)
        }
    }

    // MARK: - Reading

    /// Decodes the document bytes in `range` as UTF-8 (lossy). Copies the slice,
    /// so callers should pass small ranges (visible lines, selections).
    func string(in range: Range<Int>) -> String {
        out.removeAll(keepingCapacity: true)
        appendBytes(in: range, to: &out)
        return String(decoding: out, as: UTF8.self)
    }
    private var out: [UInt8] = []

    func appendBytes(in range: Range<Int>, to buffer: inout [UInt8]) {
        let lower = max(0, range.lowerBound)
        let upper = min(byteCount, range.upperBound)
        guard lower < upper else { return }
        var (pi, local) = locate(lower)
        var remaining = upper - lower
        while remaining > 0, pi < pieces.count {
            let p = pieces[pi]
            let take = min(p.length - local, remaining)
            switch p.source {
            case .original:
                let ptr = original.rawBase + p.start + local
                buffer.append(contentsOf: UnsafeRawBufferPointer(start: ptr, count: take))
            case .add:
                buffer.append(contentsOf: add[(p.start + local)..<(p.start + local + take)])
            }
            remaining -= take; pi += 1; local = 0
        }
    }

    func byte(at offset: Int) -> UInt8 {
        let (pi, local) = locate(offset)
        let p = pieces[pi]
        switch p.source {
        case .original: return original.byte(at: p.start + local)
        case .add:      return add[p.start + local]
        }
    }

    // MARK: - Line geometry

    /// Document byte offset where 0-based `line` begins.
    func lineStart(_ line: Int) -> Int {
        if line <= 0 { return 0 }
        if line >= lineCount { return byteCount }
        // Piece holding the `line`-th newline: largest i with linePrefix[i] < line.
        var lo = 0, hi = pieces.count - 1, hit = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if linePrefix[mid] < line { hit = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        let p = pieces[hit]
        let k = line - linePrefix[hit]   // 1-based newline within this piece
        let local = offsetAfterNewline(source: p.source, start: p.start, length: p.length, k: k)
        return bytePrefix[hit] + local
    }

    /// Exclusive end (the newline, or document end) of 0-based `line`.
    func lineEnd(_ line: Int) -> Int {
        if line + 1 >= lineCount { return byteCount }
        let nextStart = lineStart(line + 1)
        // nextStart sits just after the '\n'; back up over it (and a CR if CRLF).
        var end = nextStart - 1
        if end > 0, byte(at: end - 1) == 0x0D { end -= 1 }
        return end
    }

    // MARK: - Search

    @inline(__always)
    private func asciiLower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }

    /// First match of `needle` at or after `from`, or nil. Scans the document in
    /// overlapping ~1 MB windows via `memmem`, so it works on huge files without
    /// materializing them. Case-insensitive folding is ASCII-only.
    func nextMatch(of needle: [UInt8], from: Int, caseSensitive: Bool) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        let m = needle.count
        let n = byteCount
        guard from <= n - m else { return nil }

        let pat = caseSensitive ? needle : needle.map(asciiLower)
        let chunk = max(1 << 20, m)
        var buf: [UInt8] = []
        var windowStart = max(0, from)

        while windowStart <= n - m {
            let end = min(n, windowStart + chunk)
            buf.removeAll(keepingCapacity: true)
            appendBytes(in: windowStart..<end, to: &buf)
            if !caseSensitive { for i in buf.indices { buf[i] = asciiLower(buf[i]) } }

            if let rel = memmemIndex(haystack: buf, needle: pat) {
                return (windowStart + rel)..<(windowStart + rel + m)
            }
            if end == n { break }
            windowStart = end - (m - 1)   // overlap so straddling matches aren't missed
        }
        return nil
    }

    /// Last match strictly before `before`, or nil.
    func prevMatch(of needle: [UInt8], before: Int, caseSensitive: Bool) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        var last: Range<Int>? = nil
        var from = 0
        while let r = nextMatch(of: needle, from: from, caseSensitive: caseSensitive),
              r.lowerBound < before {
            last = r
            from = r.lowerBound + 1
        }
        return last
    }

    private func memmemIndex(haystack: [UInt8], needle: [UInt8]) -> Int? {
        haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { nd -> Int? in
                guard let hb = h.baseAddress, let nb = nd.baseAddress,
                      let found = memmem(hb, h.count, nb, nd.count) else { return nil }
                return hb.distance(to: found)
            }
        }
    }

    /// Streams the whole document to a file descriptor, piece by piece. Original
    /// slices are written straight from the mmap and add slices from the add
    /// buffer, so nothing is copied into a big intermediate buffer — saving a
    /// 10 GB file uses a fixed-size write window.
    func streamBytes(toFileDescriptor fd: Int32) -> Bool {
        var ok = true
        let bufSize = 8 << 20
        var buf = [UInt8](repeating: 0, count: bufSize)

        func writeAll(_ base: UnsafeRawPointer, _ count: Int) -> Bool {
            var w = 0
            while w < count {
                let n = write(fd, base + w, count - w)
                if n <= 0 { return false }
                w += n
            }
            return true
        }

        add.withUnsafeBytes { (addRaw: UnsafeRawBufferPointer) in
            let addBase = addRaw.baseAddress
            outer: for p in pieces {
                switch p.source {
                case .add:
                    guard let ab = addBase else { ok = false; break outer }
                    if !writeAll(ab + p.start, p.length) { ok = false; break outer }
                case .original:
                    // Stream via pread into a fixed buffer so saving a huge file
                    // doesn't page the whole original into our resident set.
                    var off = 0
                    while off < p.length {
                        let want = min(p.length - off, bufSize)
                        let result = buf.withUnsafeMutableBytes { raw -> Int in
                            let g = original.readChunk(into: raw.baseAddress!, offset: p.start + off, count: want)
                            if g <= 0 { return g }
                            return writeAll(raw.baseAddress!, g) ? g : -1
                        }
                        if result <= 0 { ok = false; break outer }
                        off += result
                    }
                }
            }
        }
        return ok
    }

    /// Recomputes cached line-feed counts for every original-buffer piece. Used
    /// while the background scan is still discovering newlines, and once before
    /// the first edit, so line counts stay correct for huge files.
    func reindexOriginalPieces() {
        for i in pieces.indices where pieces[i].source == .original {
            pieces[i].lineFeeds = lineFeeds(source: .original,
                                            start: pieces[i].start, length: pieces[i].length)
        }
        rebuild()
    }

    /// 0-based line that document `offset` falls on.
    func line(atOffset offset: Int) -> Int {
        let o = min(max(0, offset), byteCount)
        let (pi, local) = locate(o)
        if pi >= pieces.count { return linePrefix[pieces.count] }
        let p = pieces[pi]
        return linePrefix[pi] + lineFeeds(source: p.source, start: p.start, length: local)
    }

    // MARK: - Mutation

    func insert(_ text: String, at offset: Int) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        let addStart = add.count
        for (j, b) in bytes.enumerated() where b == 0x0A {
            addNewlineAfter.append(addStart + j + 1)
        }
        add.append(contentsOf: bytes)
        let newFeeds = bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }

        let (pi, local) = locate(offset)

        // Coalesce sequential typing into the previous add-piece.
        if local == 0, pi > 0 {
            let prev = pieces[pi - 1]
            if prev.source == .add, prev.start + prev.length == addStart {
                pieces[pi - 1].length += bytes.count
                pieces[pi - 1].lineFeeds += newFeeds
                rebuild()
                return
            }
        }

        let newPiece = Piece(source: .add, start: addStart, length: bytes.count, lineFeeds: newFeeds)
        if pi >= pieces.count {
            pieces.append(newPiece)
        } else if local == 0 {
            pieces.insert(newPiece, at: pi)
        } else {
            let p = pieces[pi]
            let left = Piece(source: p.source, start: p.start, length: local,
                             lineFeeds: lineFeeds(source: p.source, start: p.start, length: local))
            let right = Piece(source: p.source, start: p.start + local, length: p.length - local,
                              lineFeeds: lineFeeds(source: p.source, start: p.start + local, length: p.length - local))
            pieces.replaceSubrange(pi...pi, with: [left, newPiece, right])
        }
        rebuild()
    }

    /// Deletes `range` and returns the removed text (for undo).
    @discardableResult
    func delete(_ range: Range<Int>) -> String {
        let lower = max(0, range.lowerBound)
        let upper = min(byteCount, range.upperBound)
        guard lower < upper else { return "" }
        let removed = string(in: lower..<upper)

        let (pa, la) = locate(lower)
        let (pbRaw, lb) = locate(upper)

        var replacement: [Piece] = []
        if la > 0 {
            let p = pieces[pa]
            replacement.append(Piece(source: p.source, start: p.start, length: la,
                                     lineFeeds: lineFeeds(source: p.source, start: p.start, length: la)))
        }
        if lb > 0, pbRaw < pieces.count {
            let p = pieces[pbRaw]
            replacement.append(Piece(source: p.source, start: p.start + lb, length: p.length - lb,
                                     lineFeeds: lineFeeds(source: p.source, start: p.start + lb, length: p.length - lb)))
        }
        // Replace exactly the pieces overlapping [lower, upper). When the delete
        // ends at a piece boundary (lb == 0), that piece is untouched, so the
        // replaced range must be exclusive of it.
        let endExclusive = lb > 0 ? pbRaw + 1 : pbRaw
        pieces.replaceSubrange(pa..<endExclusive, with: replacement)
        rebuild()
        return removed
    }
}
