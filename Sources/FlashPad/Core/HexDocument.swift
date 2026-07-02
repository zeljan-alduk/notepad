import Foundation

protocol HexDocumentDelegate: AnyObject {
    /// Bytes changed (edit, undo, or redo). Byte count may have changed too.
    func hexDocumentDidChange(_ doc: HexDocument)
}

/// A binary file open in the hex editor: a byte-level piece table over the
/// read-only mmap plus an append-only add buffer, so overwrites, inserts, and
/// deletes are all cheap on multi-GB files — no byte of the original is ever
/// copied until it's edited.
///
/// Undo snapshots the piece list (tiny — one entry per surviving edit run),
/// never the bytes, so undoing a multi-GB delete costs nothing. The dirty flag
/// compares edit generations, so undoing across the save point can never lie.
final class HexDocument {
    private(set) var file: MappedFile
    let undoManager = UndoManager()
    weak var delegate: HexDocumentDelegate?

    /// URL backing this document.
    var fileURL: URL?
    /// Security-scoped URL whose access we release when this document closes.
    private let scopedURL: URL?

    private struct Piece {
        let fromAdd: Bool
        let start: Int
        let length: Int
    }

    private var pieces: [Piece] = []
    /// Prefix sums: piece i spans logical [prefixSums[i], prefixSums[i+1]).
    private var prefixSums: [Int] = [0]
    private var addBuffer: [UInt8] = []
    private(set) var byteCount = 0

    private var generation = 0
    private var savedGeneration = 0
    private var generationCounter = 0
    var isModified: Bool { generation != savedGeneration }

    /// Temp files backing swapped-in content, deleted when the document closes.
    private var spawnedTempURLs: [URL] = []

    init(file: MappedFile, url: URL?, scopedURL: URL? = nil) {
        self.file = file
        self.fileURL = url
        self.scopedURL = scopedURL
        if file.count > 0 { pieces = [Piece(fromAdd: false, start: 0, length: file.count)] }
        rebuildPrefix()
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
        for url in spawnedTempURLs { try? FileManager.default.removeItem(at: url) }
    }

    private func rebuildPrefix() {
        prefixSums = [0]
        prefixSums.reserveCapacity(pieces.count + 1)
        var total = 0
        for p in pieces { total += p.length; prefixSums.append(total) }
        byteCount = total
    }

    /// Index of the piece containing logical `offset` (offset < byteCount).
    private func pieceIndex(containing offset: Int) -> Int {
        var lo = 0, hi = pieces.count - 1, hit = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if prefixSums[mid] <= offset { hit = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return hit
    }

    func byte(at offset: Int) -> UInt8 {
        let i = pieceIndex(containing: offset)
        let p = pieces[i]
        let rel = offset - prefixSums[i]
        return p.fromAdd ? addBuffer[p.start + rel] : file.byte(at: p.start + rel)
    }

    /// True when the byte at `offset` came from an edit (drawn tinted).
    func isEdited(_ offset: Int) -> Bool {
        guard offset < byteCount else { return false }
        return pieces[pieceIndex(containing: offset)].fromAdd
    }

    func bytes(in range: Range<Int>) -> [UInt8] {
        let r = range.clamped(to: 0..<byteCount)
        return r.map { byte(at: $0) }
    }

    // MARK: - Editing

    /// Pieces covering the logical range [a, b).
    private func slice(_ a: Int, _ b: Int) -> [Piece] {
        guard b > a else { return [] }
        var out: [Piece] = []
        var i = pieceIndex(containing: a)
        var pos = prefixSums[i]
        while i < pieces.count, pos < b {
            let p = pieces[i]
            let lo = max(a, pos), hi = min(b, pos + p.length)
            if hi > lo {
                out.append(Piece(fromAdd: p.fromAdd, start: p.start + (lo - pos), length: hi - lo))
            }
            pos += p.length
            i += 1
        }
        return out
    }

    private func coalesced(_ list: [Piece]) -> [Piece] {
        var out: [Piece] = []
        for p in list where p.length > 0 {
            if let last = out.last, last.fromAdd == p.fromAdd, last.start + last.length == p.start {
                out[out.count - 1] = Piece(fromAdd: last.fromAdd, start: last.start,
                                           length: last.length + p.length)
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// The universal edit: delete `range`, then insert `bytes` at its start.
    /// One undoable step; undo restores the piece-list snapshot (never bytes).
    func replaceBytes(in range: Range<Int>, with bytes: [UInt8]) {
        let r = Range(uncheckedBounds: (max(0, range.lowerBound), min(byteCount, range.upperBound)))
        guard r.lowerBound <= r.upperBound, !(r.isEmpty && bytes.isEmpty) else { return }

        let snapshot = currentState()
        var inserted: [Piece] = []
        if !bytes.isEmpty {
            inserted = [Piece(fromAdd: true, start: addBuffer.count, length: bytes.count)]
            addBuffer.append(contentsOf: bytes)
        }
        pieces = coalesced(slice(0, r.lowerBound) + inserted + slice(r.upperBound, byteCount))
        rebuildPrefix()
        bumpGeneration()
        undoManager.registerUndo(withTarget: self) { doc in
            doc.restoreState(snapshot)
        }
        delegate?.hexDocumentDidChange(self)
    }

    /// Overwrites in place, clipped at EOF (classic hex-editor OVR typing).
    func setBytes(_ bytes: [UInt8], at offset: Int) {
        guard offset >= 0, offset < byteCount, !bytes.isEmpty else { return }
        let end = min(byteCount, offset + bytes.count)
        replaceBytes(in: offset..<end, with: Array(bytes[0..<(end - offset)]))
    }

    func insert(_ bytes: [UInt8], at offset: Int) {
        guard offset >= 0, offset <= byteCount, !bytes.isEmpty else { return }
        replaceBytes(in: offset..<offset, with: bytes)
    }

    func delete(_ range: Range<Int>) {
        let r = range.clamped(to: 0..<byteCount)
        guard !r.isEmpty else { return }
        replaceBytes(in: r, with: [])
    }

    // MARK: - Undo state

    private struct DocState {
        let file: MappedFile
        let pieces: [Piece]
        let generation: Int
    }

    private func currentState() -> DocState {
        DocState(file: file, pieces: pieces, generation: generation)
    }

    private func restoreState(_ state: DocState) {
        let current = currentState()
        file = state.file
        pieces = state.pieces
        generation = state.generation
        rebuildPrefix()
        undoManager.registerUndo(withTarget: self) { doc in
            doc.restoreState(current)
        }
        delegate?.hexDocumentDidChange(self)
    }

    private func bumpGeneration() {
        generationCounter += 1
        generation = generationCounter
    }

    enum ReplaceError: Error { case remapFailed }

    /// Replaces the whole document content (used when pixel edits re-encode an
    /// image). The new bytes go to a temp file that gets mmapped in place of
    /// the old one; the swap is a single undoable step, and the old mapping
    /// stays alive on the undo stack.
    func replaceContents(with data: Data) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashpad-image-\(getpid())-\(spawnedTempURLs.count).bin")
        try data.write(to: tmp)
        guard let mapped = MappedFile(url: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ReplaceError.remapFailed
        }
        spawnedTempURLs.append(tmp)

        let snapshot = currentState()
        file = mapped
        pieces = mapped.count > 0 ? [Piece(fromAdd: false, start: 0, length: mapped.count)] : []
        rebuildPrefix()
        bumpGeneration()
        undoManager.registerUndo(withTarget: self) { doc in
            doc.restoreState(snapshot)
        }
        delegate?.hexDocumentDidChange(self)
    }

    /// Snapshot of the current content, or nil beyond `maxBytes`. Always a
    /// copy — never a live view into the mmap — so consumers (like the image
    /// preview decoding on a background queue) can't be left reading dangling
    /// memory if the document closes or the file is swapped on save.
    func patchedData(maxBytes: Int) -> Data? {
        let n = byteCount
        guard n > 0, n <= maxBytes else { return nil }
        var data = Data(capacity: n)
        for p in pieces {
            if p.fromAdd {
                data.append(contentsOf: addBuffer[p.start ..< p.start + p.length])
            } else {
                data.append(Data(bytes: file.rawBase + p.start, count: p.length))
            }
        }
        return data
    }

    enum SaveError: Error { case readFailed }

    /// Streams the pieces to a temp file, then swaps it in with
    /// `FileManager.replaceItemAt` — the sandbox-safe atomic-save pattern (a
    /// sibling temp file in the target directory is denied under App Sandbox).
    /// Old mmaps stay alive under our references, so post-save reads stay valid.
    func save(to url: URL) throws {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                             appropriateFor: url, create: true)
        let tmp = dir.appendingPathComponent(url.lastPathComponent)
        fm.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)

        do {
            let chunkSize = 4 << 20
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            for p in pieces {
                if p.fromAdd {
                    try handle.write(contentsOf: Data(addBuffer[p.start ..< p.start + p.length]))
                    continue
                }
                var offset = 0
                while offset < p.length {
                    let want = min(chunkSize, p.length - offset)
                    let got = buffer.withUnsafeMutableBytes {
                        file.readChunk(into: $0.baseAddress!, offset: p.start + offset, count: want)
                    }
                    guard got > 0 else { throw SaveError.readFailed }
                    try handle.write(contentsOf: Data(buffer[0..<got]))
                    offset += got
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            throw error
        }

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        fileURL = url
        savedGeneration = generation
    }
}
