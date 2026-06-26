import AppKit

protocol TextDocumentDelegate: AnyObject {
    /// The text changed; `caret` is where the insertion point should land.
    func document(_ doc: TextDocument, didEditPlacingCaretAt caret: Int)
    /// Line count / size changed without an edit (background scan progress).
    func documentMetricsDidChange(_ doc: TextDocument)
}

/// Wraps a `PieceTable` with editing semantics: a single `replace` primitive,
/// undo/redo via `NSUndoManager`, a modified flag, and line indexing for the
/// background scan. The caret/selection itself lives in the view.
final class TextDocument {
    let pieceTable: PieceTable
    let file: MappedFile
    let index: LineIndex
    let undoManager = UndoManager()

    weak var delegate: TextDocumentDelegate?
    private(set) var isModified = false

    /// URL backing this document, or nil for an untitled buffer.
    var fileURL: URL?

    /// Detected byte format (encoding, BOM, line ending).
    let format: DetectedFormat
    /// Line ending inserted when the user presses Return.
    var newline: String { format.newline }

    init(file: MappedFile, index: LineIndex, url: URL?) {
        self.file = file
        self.index = index
        self.fileURL = url
        let fmt = detectFormat(file)
        self.format = fmt
        self.pieceTable = PieceTable(original: file, index: index, contentStart: fmt.contentStart)

        // We manage undo grouping ourselves so a run of typed characters folds
        // into a single undo step (see replace(_:with:coalesce:)).
        undoManager.groupsByEvent = false

        // As the background scan discovers newlines, keep the (still unedited)
        // original piece's line count live, mirroring M0's growing document.
        index.onProgress = { [weak self] in
            guard let self, !self.isModified else { return }
            self.pieceTable.reindexOriginalPieces()
            self.delegate?.documentMetricsDidChange(self)
        }
    }

    static func empty() -> TextDocument {
        let file = MappedFile.empty()
        let index = LineIndex(file: file)
        index.buildSynchronously()
        return TextDocument(file: file, index: index, url: nil)
    }

    var byteCount: Int { pieceTable.byteCount }
    var lineCount: Int { pieceTable.lineCount }

    // Open typing run, if any, for undo coalescing.
    private var typingGroupOpen = false
    private var typingRunEnd = -1

    /// An open typing run isn't undoable until closed, but the user can still
    /// invoke Undo — so the menu item must stay enabled.
    var canUndo: Bool { undoManager.canUndo || typingGroupOpen }
    var canRedo: Bool { undoManager.canRedo }

    /// Ends the current typing run, so the next typed character starts a fresh
    /// undo step. Call on caret moves, clicks, focus loss, save, etc.
    func breakUndoCoalescing() {
        if typingGroupOpen { undoManager.endUndoGrouping(); typingGroupOpen = false }
        typingRunEnd = -1
    }

    /// Replaces document bytes in `range` with `text`. Registers the inverse on
    /// the undo stack and notifies the delegate where the caret should go. When
    /// `coalesce` is true (plain typing), a contiguous run folds into one undo.
    func replace(_ range: Range<Int>, with text: String, coalesce: Bool = false) {
        let busy = undoManager.isUndoing || undoManager.isRedoing
        let typing = coalesce && !busy && range.isEmpty

        if typing, typingGroupOpen, range.lowerBound == typingRunEnd {
            applyEdit(range, text)                       // continue the open run
            typingRunEnd = range.lowerBound + text.utf8.count
            return
        }

        breakUndoCoalescing()
        if typing {
            undoManager.beginUndoGrouping(); typingGroupOpen = true
            applyEdit(range, text)
            typingRunEnd = range.lowerBound + text.utf8.count
        } else if busy {
            // During undo/redo NSUndoManager owns the grouping.
            applyEdit(range, text)
        } else {
            undoManager.beginUndoGrouping()
            applyEdit(range, text)
            undoManager.endUndoGrouping()
        }
    }

    private func applyEdit(_ range: Range<Int>, _ text: String) {
        // Before the first edit, finalize the index so every original-piece line
        // count is authoritative even if the background scan hadn't finished.
        if !index.isFinished {
            index.buildSynchronously()
            pieceTable.reindexOriginalPieces()
        }
        let removed = pieceTable.delete(range)
        if !text.isEmpty { pieceTable.insert(text, at: range.lowerBound) }
        let newRange = range.lowerBound ..< (range.lowerBound + text.utf8.count)

        undoManager.registerUndo(withTarget: self) { doc in
            doc.replace(newRange, with: removed)
        }
        isModified = true
        delegate?.document(self, didEditPlacingCaretAt: newRange.upperBound)
    }

    func markSaved() { isModified = false }

    enum SaveError: Error { case cannotCreate, writeFailed, renameFailed }

    /// Writes the document to `url` via a sibling temp file + atomic `rename`,
    /// so a crash mid-write can't corrupt the target and the mmap'd original
    /// (a different inode) stays valid. Updates `fileURL` and clears modified.
    func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).np-\(getpid())-tmp")

        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw SaveError.cannotCreate }

        if !format.bomBytes.isEmpty {
            _ = format.bomBytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        let ok = pieceTable.streamBytes(toFileDescriptor: fd)
        fsync(fd)
        close(fd)
        guard ok else {
            unlink(tmp.path)
            throw SaveError.writeFailed
        }
        guard rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw SaveError.renameFailed
        }

        fileURL = url
        markSaved()
    }
}
