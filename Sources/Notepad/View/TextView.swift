import AppKit

/// Editable viewport renderer.
///
/// Everything is addressed in **visual rows**. With word wrap off, row i is just
/// document line i. With wrap on, a long document line is split into several
/// rows (`wrapRows`). Drawing, caret, hit-testing and vertical movement all work
/// in row space, so the two modes share one code path. Only the visible rows are
/// laid out each frame, so scrolling/editing stay cheap on huge files.
final class TextView: NSView, NSTextInputClient, TextDocumentDelegate, NSUserInterfaceValidations {
    private(set) var document: TextDocument

    private(set) var font: NSFont
    private(set) var lineHeight: CGFloat
    private var ascent: CGFloat
    private var baseFont: NSFont       // user-chosen font at 100%
    private var zoom: CGFloat = 1.0
    private let leftPadding: CGFloat = 4
    private let textColor = NSColor.black

    var currentBaseFont: NSFont { baseFont }
    var onZoom: ((Int) -> Void)?

    // Selection as a pair of byte offsets. anchor == head ⇒ a caret.
    private var anchor = 0
    private var head = 0
    private var selLow: Int { min(anchor, head) }
    private var selHigh: Int { max(anchor, head) }
    private var hasSelection: Bool { anchor != head }

    private var desiredX: CGFloat?     // preserves target x across vertical moves
    private var caretVisible = true
    private var blinkTimer: Timer?
    private var maxLineWidth: CGFloat = 800

    var onCaret: ((_ line: Int, _ col: Int) -> Void)?
    var onModifiedChange: (() -> Void)?
    /// Files dropped onto the text area.
    var onOpenFiles: (([URL]) -> Void)?

    // Word wrap: a flat list of visual rows. Empty/unused when wrap is off.
    private struct WrapRow { let start: Int; let end: Int }
    private(set) var wrapEnabled = false
    private var wrapRows: [WrapRow] = []
    /// Wrap relayouts the whole document, so cap it to keep that snappy. Huge
    /// files (the scroll-heavy case) stay unwrapped.
    let wrapLineCap = 50_000

    /// Cap on bytes laid out for one visual row, so a newline-free file can't
    /// build a multi-GB CTLine.
    private let maxRenderBytes = 20_000

    init(document: TextDocument) {
        self.document = document
        let f = NSFont(name: "Consolas", size: 15)
            ?? NSFont(name: "Menlo", size: 14)
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        self.font = f
        self.baseFont = f
        self.ascent = f.ascender
        self.lineHeight = ceil(f.ascender - f.descender + f.leading) + 2
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        document.delegate = self
        registerForDraggedTypes([.fileURL])
        updateFrameSize()
    }

    // MARK: - Drag & drop (open files)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onOpenFiles?(urls)
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setDocument(_ doc: TextDocument) {
        document = doc
        doc.delegate = self
        anchor = 0; head = 0; desiredX = nil
        rebuildWrapIfNeeded()
        updateFrameSize()
        scroll(.zero)
        needsDisplay = true
        reportCaret()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { startBlink(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate(); caretVisible = false; needsDisplay = true
        return super.resignFirstResponder()
    }

    override var undoManager: UndoManager? { document.undoManager }

    private var pieceTable: PieceTable { document.pieceTable }

    // MARK: - Visual row model

    private func rowCount() -> Int { wrapEnabled ? wrapRows.count : pieceTable.lineCount }
    private func rowStart(_ i: Int) -> Int { wrapEnabled ? wrapRows[i].start : pieceTable.lineStart(i) }
    private func rowEnd(_ i: Int) -> Int { wrapEnabled ? wrapRows[i].end : pieceTable.lineEnd(i) }

    private func rowString(_ i: Int) -> String {
        let s = rowStart(i)
        let e = min(rowEnd(i), s + maxRenderBytes)
        return pieceTable.string(in: s..<e)
    }

    private func rowOfOffset(_ off: Int) -> Int {
        if !wrapEnabled { return pieceTable.line(atOffset: off) }
        guard !wrapRows.isEmpty else { return 0 }
        var lo = 0, hi = wrapRows.count - 1, hit = 0
        while lo <= hi {
            let m = (lo + hi) / 2
            if wrapRows[m].start <= off { hit = m; lo = m + 1 } else { hi = m - 1 }
        }
        return hit
    }

    // MARK: - Core Text helpers

    private func ctLine(_ s: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: textColor]))
    }

    /// X position (view coords) of `off` within visual row `i`.
    private func xForOffset(_ off: Int, inRow i: Int, rowStr: String) -> CGFloat {
        let byteInRow = max(0, off - rowStart(i))
        let u16 = utf16Index(in: rowStr, byteOffset: byteInRow)
        return leftPadding + CTLineGetOffsetForStringIndex(ctLine(rowStr), u16, nil)
    }

    private func offsetAt(point: NSPoint) -> Int {
        let total = rowCount()
        guard total > 0 else { return 0 }
        let i = max(0, min(total - 1, Int((point.y / lineHeight).rounded(.down))))
        let s = rowString(i)
        let u16 = CTLineGetStringIndexForPosition(ctLine(s), CGPoint(x: point.x - leftPadding, y: 0))
        return rowStart(i) + min(byteOffset(in: s, utf16Index: u16), s.utf8.count)
    }

    private func utf16Index(in s: String, byteOffset: Int) -> Int {
        if byteOffset <= 0 { return 0 }
        let bytes = Array(s.utf8)
        let clamped = min(byteOffset, bytes.count)
        return String(decoding: bytes[0..<clamped], as: UTF8.self).utf16.count
    }

    private func byteOffset(in s: String, utf16Index i: Int) -> Int {
        let u = s.utf16
        guard i > 0 else { return 0 }
        guard let idx = u.index(u.startIndex, offsetBy: i, limitedBy: u.endIndex),
              let sidx = idx.samePosition(in: s) else { return s.utf8.count }
        return s[..<sidx].utf8.count
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        let total = rowCount()
        guard total > 0 else { drawCaretIfNeeded(); return }

        let first = max(0, Int((dirtyRect.minY / lineHeight).rounded(.down)))
        let last = min(total - 1, Int((dirtyRect.maxY / lineHeight).rounded(.down)))
        guard first <= last else { return }

        let ctx = NSGraphicsContext.current!.cgContext
        let lo = selLow, hi = selHigh

        for i in first...last {
            let start = rowStart(i), end = rowEnd(i)
            let s = rowString(i)
            let ct = ctLine(s)
            let y = CGFloat(i) * lineHeight

            if hi > lo, lo <= end, hi >= start {
                let xs = (lo <= start) ? leftPadding : xForOffset(max(lo, start), inRow: i, rowStr: s)
                let xe = (hi > end) ? bounds.width : xForOffset(min(hi, end), inRow: i, rowStr: s)
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: xs, y: y, width: max(1, xe - xs), height: lineHeight).fill()
            }

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: leftPadding, y: y + ascent)
            ctx.scaleBy(x: 1, y: -1)
            CTLineDraw(ct, ctx)
            ctx.restoreGState()

            if !wrapEnabled {
                let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)) + leftPadding * 2
                if w > maxLineWidth { maxLineWidth = w; scheduleFrameSizeUpdate() }
            }
        }
        drawCaretIfNeeded()
    }

    private func drawCaretIfNeeded() {
        guard caretVisible, !hasSelection, window?.firstResponder === self else { return }
        let i = rowOfOffset(head)
        guard rowCount() > 0 else { return }
        let s = rowString(i)
        let x = xForOffset(head, inRow: i, rowStr: s)
        let y = CGFloat(i) * lineHeight
        NSColor.black.setFill()
        NSRect(x: x, y: y + 1, width: 1, height: lineHeight - 2).fill()
    }

    // MARK: - Word wrap

    @discardableResult
    func setWrap(_ on: Bool) -> Bool {
        if on, pieceTable.lineCount > wrapLineCap { return false }
        wrapEnabled = on
        enclosingScrollView?.hasHorizontalScroller = !on
        if !on { wrapRows = [] } else { buildWrapRows() }
        maxLineWidth = 800
        updateFrameSize()
        needsDisplay = true
        ensureCaretVisible()
        return true
    }

    /// Rebuild wrap layout after anything that changes widths or content.
    private func rebuildWrapIfNeeded() {
        guard wrapEnabled else { return }
        if pieceTable.lineCount > wrapLineCap { setWrap(false); return }  // grew too big
        buildWrapRows()
        updateFrameSize()
        needsDisplay = true
    }

    private func buildWrapRows() {
        wrapRows.removeAll(keepingCapacity: true)
        let width = max(40, (enclosingScrollView?.contentSize.width ?? bounds.width) - leftPadding * 2)
        let n = pieceTable.lineCount
        for line in 0..<n {
            let start = pieceTable.lineStart(line)
            let end = pieceTable.lineEnd(line)
            if end <= start { wrapRows.append(WrapRow(start: start, end: start)); continue }
            let s = pieceTable.string(in: start..<min(end, start + maxRenderBytes))
            let attr = NSAttributedString(string: s, attributes: [.font: font])
            let ts = CTTypesetterCreateWithAttributedString(attr)
            let len = (s as NSString).length
            var idx = 0
            while idx < len {
                var cnt = CTTypesetterSuggestLineBreak(ts, idx, Double(width))
                if cnt <= 0 { cnt = 1 }
                let segEnd = min(idx + cnt, len)
                let sByte = start + byteOffset(in: s, utf16Index: idx)
                let eByte = start + byteOffset(in: s, utf16Index: segEnd)
                wrapRows.append(WrapRow(start: sByte, end: eByte))
                idx = segEnd
            }
        }
    }

    // MARK: - Frame sizing

    private var frameUpdateScheduled = false
    private func scheduleFrameSizeUpdate() {
        if frameUpdateScheduled { return }
        frameUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.frameUpdateScheduled = false
            self?.updateFrameSize()
        }
    }

    private func updateFrameSize() {
        let viewportH = enclosingScrollView?.contentSize.height ?? bounds.height
        let viewportW = enclosingScrollView?.contentSize.width ?? bounds.width
        let h = max(CGFloat(rowCount()) * lineHeight, viewportH)
        let w = wrapEnabled ? viewportW : max(maxLineWidth, viewportW)
        if frame.size.height != h || frame.size.width != w {
            setFrameSize(NSSize(width: w, height: h))
        }
    }

    // MARK: - Caret / selection movement

    private func setSelection(anchor a: Int, head h: Int) {
        let n = pieceTable.byteCount
        anchor = max(0, min(n, a))
        head = max(0, min(n, h))
        restartBlink()
        ensureCaretVisible()
        needsDisplay = true
        reportCaret()
    }

    private func move(to newHead: Int, extend: Bool) {
        setSelection(anchor: extend ? anchor : newHead, head: newHead)
    }

    private func reportCaret() {
        let line = pieceTable.line(atOffset: head)
        let col = pieceTable.string(in: pieceTable.lineStart(line)..<head).count + 1
        onCaret?(line + 1, col)
    }

    private func nextOffset(after off: Int) -> Int {
        let n = pieceTable.byteCount
        guard off < n else { return n }
        let line = pieceTable.line(atOffset: off)
        let end = pieceTable.lineEnd(line)
        if off >= end { return pieceTable.lineStart(line + 1) }   // cross newline
        let s = pieceTable.string(in: pieceTable.lineStart(line)..<end)
        let rel = off - pieceTable.lineStart(line)
        guard let i = s.utf8.index(s.utf8.startIndex, offsetBy: rel, limitedBy: s.utf8.endIndex),
              let si = i.samePosition(in: s), si < s.endIndex else { return end }
        return pieceTable.lineStart(line) + s[..<s.index(after: si)].utf8.count
    }

    private func prevOffset(before off: Int) -> Int {
        guard off > 0 else { return 0 }
        let line = pieceTable.line(atOffset: off)
        let start = pieceTable.lineStart(line)
        if off <= start { return pieceTable.lineEnd(line - 1) }   // cross newline
        let s = pieceTable.string(in: start..<pieceTable.lineEnd(line))
        let rel = off - start
        guard let i = s.utf8.index(s.utf8.startIndex, offsetBy: rel, limitedBy: s.utf8.endIndex),
              let si = i.samePosition(in: s) else { return start }
        return start + s[..<s.index(before: si)].utf8.count
    }

    private func verticalMove(by delta: Int, extend: Bool) {
        let i = rowOfOffset(head)
        let target = i + delta
        if target < 0 { move(to: 0, extend: extend); desiredX = nil; return }
        if target >= rowCount() { move(to: pieceTable.byteCount, extend: extend); desiredX = nil; return }
        if desiredX == nil { desiredX = xForOffset(head, inRow: i, rowStr: rowString(i)) }
        let s = rowString(target)
        let rel = CGPoint(x: (desiredX ?? leftPadding) - leftPadding, y: 0)
        let u16 = CTLineGetStringIndexForPosition(ctLine(s), rel)
        let newHead = rowStart(target) + min(byteOffset(in: s, utf16Index: u16), s.utf8.count)
        let saved = desiredX
        move(to: newHead, extend: extend)
        desiredX = saved
    }

    private func rowHome(_ extend: Bool) { move(to: rowStart(rowOfOffset(head)), extend: extend); desiredX = nil }
    private func rowEndEdge(_ extend: Bool) { move(to: rowEnd(rowOfOffset(head)), extend: extend); desiredX = nil }

    // MARK: - Editing

    private func replaceSelection(with text: String) {
        document.replace(selLow..<selHigh, with: text)
    }

    func document(_ doc: TextDocument, didEditPlacingCaretAt caret: Int) {
        desiredX = nil
        anchor = caret; head = caret
        rebuildWrapIfNeeded()
        updateFrameSize()
        needsDisplay = true
        restartBlink()
        ensureCaretVisible()
        reportCaret()
        onModifiedChange?()
    }

    func documentMetricsDidChange(_ doc: TextDocument) {
        rebuildWrapIfNeeded()
        updateFrameSize()
        needsDisplay = true
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        replaceSelection(with: text)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            replaceSelection(with: document.newline)
        case #selector(insertTab(_:)): replaceSelection(with: "\t")
        case #selector(deleteBackward(_:)):
            if hasSelection { replaceSelection(with: "") }
            else { document.replace(prevOffset(before: head)..<head, with: "") }
        case #selector(deleteForward(_:)):
            if hasSelection { replaceSelection(with: "") }
            else { document.replace(head..<nextOffset(after: head), with: "") }
        case #selector(moveLeft(_:)):
            move(to: hasSelection ? selLow : prevOffset(before: head), extend: false); desiredX = nil
        case #selector(moveRight(_:)):
            move(to: hasSelection ? selHigh : nextOffset(after: head), extend: false); desiredX = nil
        case #selector(moveLeftAndModifySelection(_:)):
            move(to: prevOffset(before: head), extend: true); desiredX = nil
        case #selector(moveRightAndModifySelection(_:)):
            move(to: nextOffset(after: head), extend: true); desiredX = nil
        case #selector(moveUp(_:)): verticalMove(by: -1, extend: false)
        case #selector(moveDown(_:)): verticalMove(by: 1, extend: false)
        case #selector(moveUpAndModifySelection(_:)): verticalMove(by: -1, extend: true)
        case #selector(moveDownAndModifySelection(_:)): verticalMove(by: 1, extend: true)
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)): rowHome(false)
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)): rowEndEdge(false)
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)): rowHome(true)
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)): rowEndEdge(true)
        case #selector(moveToBeginningOfDocument(_:)): move(to: 0, extend: false); desiredX = nil
        case #selector(moveToEndOfDocument(_:)): move(to: pieceTable.byteCount, extend: false); desiredX = nil
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)): move(to: 0, extend: true)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)): move(to: pieceTable.byteCount, extend: true)
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): verticalMove(by: -visibleRowCount, extend: false)
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): verticalMove(by: visibleRowCount, extend: false)
        case #selector(pageUpAndModifySelection(_:)): verticalMove(by: -visibleRowCount, extend: true)
        case #selector(pageDownAndModifySelection(_:)): verticalMove(by: visibleRowCount, extend: true)
        default: break
        }
    }

    private var visibleRowCount: Int {
        max(1, Int((enclosingScrollView?.contentSize.height ?? bounds.height) / lineHeight) - 1)
    }

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func hasMarkedText() -> Bool { false }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let i = rowOfOffset(head)
        let x = xForOffset(head, inRow: i, rowStr: rowString(i))
        let inWindow = convert(NSRect(x: x, y: CGFloat(i) * lineHeight, width: 1, height: lineHeight), to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let off = offsetAt(point: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.shift) { move(to: off, extend: true) }
        else { setSelection(anchor: off, head: off) }
        desiredX = nil
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        move(to: offsetAt(point: convert(event.locationInWindow, from: nil)), extend: true)
        desiredX = nil
    }

    // MARK: - Standard editing actions

    @objc override func selectAll(_ sender: Any?) { setSelection(anchor: 0, head: pieceTable.byteCount) }

    @objc func copy(_ sender: Any?) {
        guard hasSelection else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pieceTable.string(in: selLow..<selHigh), forType: .string)
    }
    @objc func cut(_ sender: Any?) { guard hasSelection else { return }; copy(sender); replaceSelection(with: "") }
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        replaceSelection(with: text)
    }
    @objc func undo(_ sender: Any?) { document.undoManager.undo() }
    @objc func redo(_ sender: Any?) { document.undoManager.redo() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return hasSelection
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        case #selector(undo(_:)): return document.undoManager.canUndo
        case #selector(redo(_:)): return document.undoManager.canRedo
        default: return true
        }
    }

    // MARK: - Font & Zoom

    func setBaseFont(_ f: NSFont) { baseFont = f; applyFont() }
    @objc func changeFont(_ sender: Any?) { setBaseFont(NSFontManager.shared.convert(baseFont)) }
    @objc func zoomIn(_ sender: Any?)  { zoom = min(5.0, zoom + 0.1); applyFont() }
    @objc func zoomOut(_ sender: Any?) { zoom = max(0.3, zoom - 0.1); applyFont() }
    @objc func resetZoom(_ sender: Any?) { zoom = 1.0; applyFont() }

    private func applyFont() {
        font = NSFont(descriptor: baseFont.fontDescriptor, size: baseFont.pointSize * zoom) ?? baseFont
        ascent = font.ascender
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        maxLineWidth = 800
        rebuildWrapIfNeeded()
        updateFrameSize()
        needsDisplay = true
        ensureCaretVisible()
        onZoom?(Int((zoom * 100).rounded()))
    }

    // MARK: - Find / Replace / Go To

    var selectionText: String { pieceTable.string(in: selLow..<selHigh) }

    @discardableResult
    func findNext(_ needle: String, caseSensitive: Bool, forward: Bool) -> Bool {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty else { return false }
        let range: Range<Int>? = forward
            ? (pieceTable.nextMatch(of: bytes, from: selHigh, caseSensitive: caseSensitive)
               ?? pieceTable.nextMatch(of: bytes, from: 0, caseSensitive: caseSensitive))
            : (pieceTable.prevMatch(of: bytes, before: selLow, caseSensitive: caseSensitive)
               ?? pieceTable.prevMatch(of: bytes, before: pieceTable.byteCount, caseSensitive: caseSensitive))
        guard let r = range else { return false }
        setSelection(anchor: r.lowerBound, head: r.upperBound)
        desiredX = nil
        return true
    }

    @discardableResult
    func replaceThenFind(_ needle: String, with replacement: String, caseSensitive: Bool) -> Bool {
        let sel = selectionText
        let isMatch = caseSensitive ? (sel == needle) : (sel.lowercased() == needle.lowercased())
        if hasSelection, isMatch { document.replace(selLow..<selHigh, with: replacement) }
        return findNext(needle, caseSensitive: caseSensitive, forward: true)
    }

    func replaceAll(_ needle: String, with replacement: String, caseSensitive: Bool) -> Int {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty else { return 0 }
        let replBytes = replacement.utf8.count
        document.undoManager.beginUndoGrouping()
        var count = 0, from = 0
        while let r = pieceTable.nextMatch(of: bytes, from: from, caseSensitive: caseSensitive) {
            document.replace(r, with: replacement)
            count += 1
            from = r.lowerBound + replBytes
        }
        document.undoManager.endUndoGrouping()
        return count
    }

    func goToLine(_ line1Based: Int) {
        let line = max(0, min(pieceTable.lineCount - 1, line1Based - 1))
        let off = pieceTable.lineStart(line)
        setSelection(anchor: off, head: off)
        desiredX = nil
    }

    // MARK: - Caret blink

    private func startBlink() {
        blinkTimer?.invalidate()
        caretVisible = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.caretVisible.toggle()
            self?.needsDisplay = true
        }
        needsDisplay = true
    }
    private func restartBlink() { if window?.firstResponder === self { startBlink() } }

    // MARK: - Scroll caret into view + resize

    private func ensureCaretVisible() {
        guard rowCount() > 0 else { return }
        let i = rowOfOffset(head)
        let x = xForOffset(head, inRow: i, rowStr: rowString(i))
        scrollToVisible(NSRect(x: x - 2, y: CGFloat(i) * lineHeight, width: 4, height: lineHeight))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = enclosingScrollView?.contentView {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipResized),
                name: NSView.frameDidChangeNotification, object: clip)
        }
        updateFrameSize()
    }

    @objc private func clipResized() {
        // Wrap width follows the viewport.
        if wrapEnabled { rebuildWrapIfNeeded() }
        updateFrameSize()
    }
}
