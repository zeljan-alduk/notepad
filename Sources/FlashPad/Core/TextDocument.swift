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

    // A change counter (à la NSDocument): +1 per edit/redo, -1 per undo. The
    // document is "modified" only when it differs from its value at last save,
    // so undoing back to the saved state clears the dirty marker.
    private var changeCount = 0
    private var savedChangeCount = 0
    var isModified: Bool { changeCount != savedChangeCount }

    /// URL backing this document, or nil for an untitled buffer.
    var fileURL: URL?

    /// Encoding used to read this file and to write it back.
    var encoding: FileEncoding
    /// Line ending inserted when the user presses Return.
    var lineEnding: LineEndingInfo
    var newline: String { lineEnding.newline }
    var encodingLabel: String { encoding.label }
    var lineEndingLabel: String { lineEnding.label }

    /// Transcoded UTF-8 backing file to delete when this document closes.
    private let tempURL: URL?

    init(file: MappedFile, index: LineIndex, url: URL?,
         encoding: FileEncoding = .utf8,
         lineEnding: LineEndingInfo = .crlf,
         contentStart: Int = 0,
         tempURL: URL? = nil) {
        self.file = file
        self.index = index
        self.fileURL = url
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.tempURL = tempURL
        self.pieceTable = PieceTable(original: file, index: index, contentStart: contentStart)

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

    deinit {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
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
        changeCount += undoManager.isUndoing ? -1 : 1
        delegate?.document(self, didEditPlacingCaretAt: newRange.upperBound)
    }

    func markSaved() { savedChangeCount = changeCount }

    enum SaveError: Error { case cannotCreate, writeFailed, renameFailed }

    /// Writes the document to `url` in `encoding` via a sibling temp file + atomic
    /// `rename`. UTF-8/UTF-8-BOM stream from the piece table (low memory, any
    /// size); UTF-16/ANSI transcode the whole document (rare, typically small).
    func save(to url: URL, as encoding: FileEncoding) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).np-\(getpid())-tmp")

        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw SaveError.cannotCreate }

        var ok = true
        switch encoding {
        case .utf8, .utf8BOM:
            if encoding == .utf8BOM {
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                _ = bom.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
            ok = pieceTable.streamBytes(toFileDescriptor: fd)
        case .utf16LE, .utf16BE, .ansi:
            let content = pieceTable.string(in: 0..<pieceTable.byteCount)
            let data = encoding.encode(content)
            ok = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return true }
                return write(fd, base, raw.count) == raw.count
            }
        }
        fsync(fd)
        close(fd)
        guard ok else { unlink(tmp.path); throw SaveError.writeFailed }
        guard rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw SaveError.renameFailed }

        fileURL = url
        self.encoding = encoding
        markSaved()
    }
}
