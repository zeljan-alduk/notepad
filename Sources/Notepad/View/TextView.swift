import AppKit

/// Editable viewport renderer.
///
/// Draws only the visible lines each frame with Core Text, so editing and
/// scrolling stay cheap on huge files. Caret/selection are byte offsets into the
/// document; the `PieceTable` answers all line geometry.
final class TextView: NSView, NSTextInputClient, TextDocumentDelegate, NSUserInterfaceValidations {
    private(set) var document: TextDocument

    let font: NSFont
    let lineHeight: CGFloat
    private let ascent: CGFloat
    private let leftPadding: CGFloat = 4
    private let textColor = NSColor.black

    // Selection as a pair of byte offsets. anchor == head ⇒ a caret.
    private var anchor = 0
    private var head = 0
    private var selLow: Int { min(anchor, head) }
    private var selHigh: Int { max(anchor, head) }
    private var hasSelection: Bool { anchor != head }

    /// Preserves the target x across vertical moves.
    private var desiredX: CGFloat?

    private var caretVisible = true
    private var blinkTimer: Timer?
    private var maxLineWidth: CGFloat = 800

    /// Reports caret line/column (1-based) for the status bar.
    var onCaret: ((_ line: Int, _ col: Int) -> Void)?
    /// Fires when the modified flag may have changed (title dirty marker).
    var onModifiedChange: (() -> Void)?

    init(document: TextDocument) {
        self.document = document
        let f = NSFont(name: "Consolas", size: 15)
            ?? NSFont(name: "Menlo", size: 14)
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        self.font = f
        self.ascent = f.ascender
        self.lineHeight = ceil(f.ascender - f.descender + f.leading) + 2
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        document.delegate = self
        updateFrameSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setDocument(_ doc: TextDocument) {
        document = doc
        doc.delegate = self
        anchor = 0; head = 0; desiredX = nil
        updateFrameSize()
        scroll(.zero)
        needsDisplay = true
        reportCaret()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        startBlink(); return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate(); caretVisible = false; needsDisplay = true
        return super.resignFirstResponder()
    }

    // The Edit menu's Undo/Redo route through the responder chain to this.
    override var undoManager: UndoManager? { document.undoManager }

    // MARK: - Geometry helpers

    private var pieceTable: PieceTable { document.pieceTable }

    /// Hard cap on bytes rendered/measured for a single line. Word-wrap is off
    /// (Notepad default), so a pathological newline-free file could otherwise
    /// build a multi-GB CTLine. No screen shows 20k columns anyway.
    private let maxRenderBytes = 20_000

    private func lineString(_ line: Int) -> String {
        let start = pieceTable.lineStart(line)
        let end = min(pieceTable.lineEnd(line), start + maxRenderBytes)
        return pieceTable.string(in: start..<end)
    }

    private func ctLine(_ s: String) -> CTLine {
        let attr = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        return CTLineCreateWithAttributedString(attr)
    }

    /// X position (view coords) of a document offset on its line.
    private func xFor(offset: Int, line: Int, lineStr: String) -> CGFloat {
        let byteInLine = offset - pieceTable.lineStart(line)
        let u16 = utf16Index(in: lineStr, byteOffset: byteInLine)
        let x = CTLineGetOffsetForStringIndex(ctLine(lineStr), u16, nil)
        return leftPadding + x
    }

    /// Document offset nearest a point.
    private func offsetAt(point: NSPoint) -> Int {
        let total = pieceTable.lineCount
        var line = Int((point.y / lineHeight).rounded(.down))
        line = max(0, min(total - 1, line))
        let s = lineString(line)
        let rel = CGPoint(x: point.x - leftPadding, y: 0)
        let u16 = CTLineGetStringIndexForPosition(ctLine(s), rel)
        let byteInLine = byteOffset(in: s, utf16Index: u16)
        return pieceTable.lineStart(line) + min(byteInLine, s.utf8.count)
    }

    // MARK: - UTF-8 <-> UTF-16 within a line

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

        let total = pieceTable.lineCount
        guard total > 0 else { drawCaretIfNeeded(); return }

        let first = max(0, Int((dirtyRect.minY / lineHeight).rounded(.down)))
        let last = min(total - 1, Int((dirtyRect.maxY / lineHeight).rounded(.down)))
        guard first <= last else { return }

        let ctx = NSGraphicsContext.current!.cgContext
        let lo = selLow, hi = selHigh

        for line in first...last {
            let start = pieceTable.lineStart(line)
            let end = pieceTable.lineEnd(line)
            let s = lineString(line)
            let ct = ctLine(s)
            let y = CGFloat(line) * lineHeight

            // Selection highlight for this line.
            if hi > lo, lo <= end, hi >= start {
                let xs = (lo <= start) ? leftPadding : xFor(offset: max(lo, start), line: line, lineStr: s)
                var xe: CGFloat
                if hi > end {            // selection runs through the newline
                    xe = bounds.width
                } else {
                    xe = xFor(offset: min(hi, end), line: line, lineStr: s)
                }
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: xs, y: y, width: max(1, xe - xs), height: lineHeight).fill()
            }

            // Text.
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: leftPadding, y: y + ascent)
            ctx.scaleBy(x: 1, y: -1)
            CTLineDraw(ct, ctx)
            ctx.restoreGState()

            let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)) + leftPadding * 2
            if w > maxLineWidth { maxLineWidth = w; scheduleFrameSizeUpdate() }
        }

        drawCaretIfNeeded()
    }

    private func drawCaretIfNeeded() {
        guard caretVisible, !hasSelection, window?.firstResponder === self else { return }
        let line = pieceTable.line(atOffset: head)
        let s = lineString(line)
        let x = xFor(offset: head, line: line, lineStr: s)
        let y = CGFloat(line) * lineHeight
        NSColor.black.setFill()
        NSRect(x: x, y: y + 1, width: 1, height: lineHeight - 2).fill()
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
        let h = max(CGFloat(pieceTable.lineCount) * lineHeight, enclosingScrollView?.contentSize.height ?? bounds.height)
        let w = max(maxLineWidth, enclosingScrollView?.contentSize.width ?? bounds.width)
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
        if off >= end { return pieceTable.lineStart(line + 1) }  // cross newline
        let s = lineString(line)
        let rel = off - pieceTable.lineStart(line)
        guard let i = s.utf8.index(s.utf8.startIndex, offsetBy: rel, limitedBy: s.utf8.endIndex),
              let si = i.samePosition(in: s), si < s.endIndex else { return end }
        let nextChar = s.index(after: si)
        return pieceTable.lineStart(line) + s[..<nextChar].utf8.count
    }

    private func prevOffset(before off: Int) -> Int {
        guard off > 0 else { return 0 }
        let line = pieceTable.line(atOffset: off)
        let start = pieceTable.lineStart(line)
        if off <= start { return pieceTable.lineEnd(line - 1) }  // cross newline
        let s = lineString(line)
        let rel = off - start
        guard let i = s.utf8.index(s.utf8.startIndex, offsetBy: rel, limitedBy: s.utf8.endIndex),
              let si = i.samePosition(in: s) else { return start }
        let prevChar = s.index(before: si)
        return start + s[..<prevChar].utf8.count
    }

    private func verticalMove(by delta: Int, extend: Bool) {
        let line = pieceTable.line(atOffset: head)
        let target = line + delta
        if target < 0 { move(to: 0, extend: extend); return }
        if target >= pieceTable.lineCount { move(to: pieceTable.byteCount, extend: extend); return }
        if desiredX == nil {
            desiredX = xFor(offset: head, line: line, lineStr: lineString(line))
        }
        let s = lineString(target)
        let rel = CGPoint(x: (desiredX ?? leftPadding) - leftPadding, y: 0)
        let u16 = CTLineGetStringIndexForPosition(ctLine(s), rel)
        let newHead = pieceTable.lineStart(target) + min(byteOffset(in: s, utf16Index: u16), s.utf8.count)
        let saved = desiredX
        move(to: newHead, extend: extend)
        desiredX = saved   // preserve across consecutive vertical moves
    }

    // MARK: - Editing primitives

    private func replaceSelection(with text: String) {
        document.replace(selLow..<selHigh, with: text)
        // caret placement comes back via the delegate callback
    }

    func document(_ doc: TextDocument, didEditPlacingCaretAt caret: Int) {
        desiredX = nil
        anchor = caret; head = caret
        updateFrameSize()
        needsDisplay = true
        restartBlink()
        ensureCaretVisible()
        reportCaret()
        onModifiedChange?()
    }

    func documentMetricsDidChange(_ doc: TextDocument) {
        updateFrameSize()
        needsDisplay = true
    }

    // MARK: - NSTextInputClient (text entry)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        replaceSelection(with: text)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): replaceSelection(with: "\n")
        case #selector(insertTab(_:)): replaceSelection(with: "\t")
        case #selector(deleteBackward(_:)):
            if hasSelection { replaceSelection(with: "") }
            else { let p = prevOffset(before: head); document.replace(p..<head, with: "") }
        case #selector(deleteForward(_:)):
            if hasSelection { replaceSelection(with: "") }
            else { let nx = nextOffset(after: head); document.replace(head..<nx, with: "") }
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
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)):
            move(to: pieceTable.lineStart(pieceTable.line(atOffset: head)), extend: false); desiredX = nil
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)):
            move(to: pieceTable.lineEnd(pieceTable.line(atOffset: head)), extend: false); desiredX = nil
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)):
            move(to: pieceTable.lineStart(pieceTable.line(atOffset: head)), extend: true); desiredX = nil
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)):
            move(to: pieceTable.lineEnd(pieceTable.line(atOffset: head)), extend: true); desiredX = nil
        case #selector(moveToBeginningOfDocument(_:)): move(to: 0, extend: false); desiredX = nil
        case #selector(moveToEndOfDocument(_:)): move(to: pieceTable.byteCount, extend: false); desiredX = nil
        case #selector(moveToBeginningOfDocumentAndModifySelection(_:)): move(to: 0, extend: true)
        case #selector(moveToEndOfDocumentAndModifySelection(_:)): move(to: pieceTable.byteCount, extend: true)
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): verticalMove(by: -visibleLineCount, extend: false)
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): verticalMove(by: visibleLineCount, extend: false)
        case #selector(pageUpAndModifySelection(_:)): verticalMove(by: -visibleLineCount, extend: true)
        case #selector(pageDownAndModifySelection(_:)): verticalMove(by: visibleLineCount, extend: true)
        case #selector(insertNewlineIgnoringFieldEditor(_:)): replaceSelection(with: "\n")
        default: break
        }
    }

    private var visibleLineCount: Int {
        max(1, Int((enclosingScrollView?.contentSize.height ?? bounds.height) / lineHeight) - 1)
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    // Required NSTextInputClient stubs (no marked-text/IME composition in M1).
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func hasMarkedText() -> Bool { false }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let line = pieceTable.line(atOffset: head)
        let x = xFor(offset: head, line: line, lineStr: lineString(line))
        let rectInView = NSRect(x: x, y: CGFloat(line) * lineHeight, width: 1, height: lineHeight)
        let inWindow = convert(rectInView, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let off = offsetAt(point: p)
        if event.modifierFlags.contains(.shift) {
            move(to: off, extend: true)
        } else {
            setSelection(anchor: off, head: off)
        }
        desiredX = nil
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        move(to: offsetAt(point: p), extend: true)
        desiredX = nil
    }

    // MARK: - Standard editing actions (Edit menu / shortcuts)

    @objc override func selectAll(_ sender: Any?) {
        setSelection(anchor: 0, head: pieceTable.byteCount)
    }

    @objc func copy(_ sender: Any?) {
        guard hasSelection else { return }
        let text = pieceTable.string(in: selLow..<selHigh)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard hasSelection else { return }
        copy(sender)
        replaceSelection(with: "")
    }

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

    // MARK: - Find / Replace / Go To

    var selectionText: String { pieceTable.string(in: selLow..<selHigh) }

    @discardableResult
    func findNext(_ needle: String, caseSensitive: Bool, forward: Bool) -> Bool {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty else { return false }
        var range: Range<Int>?
        if forward {
            range = pieceTable.nextMatch(of: bytes, from: selHigh, caseSensitive: caseSensitive)
                 ?? pieceTable.nextMatch(of: bytes, from: 0, caseSensitive: caseSensitive)   // wrap
        } else {
            range = pieceTable.prevMatch(of: bytes, before: selLow, caseSensitive: caseSensitive)
                 ?? pieceTable.prevMatch(of: bytes, before: pieceTable.byteCount, caseSensitive: caseSensitive)
        }
        guard let r = range else { return false }
        setSelection(anchor: r.lowerBound, head: r.upperBound)
        desiredX = nil
        return true
    }

    /// If the current selection is the search term, replace it; then find next.
    @discardableResult
    func replaceThenFind(_ needle: String, with replacement: String, caseSensitive: Bool) -> Bool {
        let sel = selectionText
        let isMatch = caseSensitive ? (sel == needle)
                                    : (sel.lowercased() == needle.lowercased())
        if hasSelection, isMatch {
            document.replace(selLow..<selHigh, with: replacement)
        }
        return findNext(needle, caseSensitive: caseSensitive, forward: true)
    }

    func replaceAll(_ needle: String, with replacement: String, caseSensitive: Bool) -> Int {
        let bytes = Array(needle.utf8)
        guard !bytes.isEmpty else { return 0 }
        let replBytes = replacement.utf8.count
        document.undoManager.beginUndoGrouping()
        var count = 0
        var from = 0
        while let r = pieceTable.nextMatch(of: bytes, from: from, caseSensitive: caseSensitive) {
            document.replace(r, with: replacement)
            count += 1
            from = r.lowerBound + replBytes   // continue past the inserted text
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
            guard let self else { return }
            self.caretVisible.toggle()
            self.needsDisplay = true
        }
        needsDisplay = true
    }
    private func restartBlink() {
        if window?.firstResponder === self { startBlink() }
    }

    // MARK: - Scroll caret into view

    private func ensureCaretVisible() {
        let line = pieceTable.line(atOffset: head)
        let s = lineString(line)
        let x = xFor(offset: head, line: line, lineStr: s)
        let rect = NSRect(x: x - 2, y: CGFloat(line) * lineHeight, width: 4, height: lineHeight)
        scrollToVisible(rect)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateFrameSize()
    }
}
