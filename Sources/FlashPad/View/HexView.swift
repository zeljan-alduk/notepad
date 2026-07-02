import AppKit

/// Viewport-rendered hex editor: an offset gutter, 16 hex byte cells, and an
/// ASCII column, all addressed by byte offset.
///
/// The view is always viewport-sized and owns its scroll offset (`scrollY`),
/// driving an external NSScroller — it is never a giant NSScrollView document
/// view. AppKit compositing breaks down past a few hundred thousand points of
/// view height (stale layer tiles, blank backing stores), and a multi-GB file
/// at 16 bytes per row is *billions* of points tall. Owning the offset keeps
/// every drawn coordinate small no matter the file size.
///
/// Editing is overwrite-only (the classic hex-editor model): typing hex digits
/// or ASCII replaces bytes in place, Delete reverts bytes to their on-disk
/// value, and edited bytes are tinted until saved.
final class HexView: NSView, HexDocumentDelegate, NSUserInterfaceValidations {
    private let document: HexDocument

    private enum Pane { case hex, ascii }

    private var font: NSFont
    private let baseFontSize: CGFloat = 13
    private var zoom: CGFloat = 1.0
    private var charW: CGFloat = 8
    private var lineHeight: CGFloat = 18
    private var ascent: CGFloat = 12

    private let bytesPerRow = 16
    private let leftPadding: CGFloat = 6
    private var offsetDigits = 8
    /// User-adjustable extra gap between the hex cells and the ASCII column
    /// (dragged via the divider zone between the two sections).
    private var asciiExtraGap: CGFloat = 0

    // Selection as byte offsets; anchor == head ⇒ a caret. `head` may sit at EOF.
    private var anchor = 0
    private var head = 0
    private var selLow: Int { min(anchor, head) }
    private var selHigh: Int { max(anchor, head) }
    private var hasSelection: Bool { anchor != head }
    private var activePane: Pane = .hex
    /// The next typed hex digit fills the high nibble of the byte at `head`.
    private var highNibble = true
    /// Insert mode: typing inserts new bytes instead of overwriting. Typing at
    /// EOF always inserts (files can grow at the end in either mode).
    private(set) var insertMode = false

    private var caretVisible = true
    private var blinkTimer: Timer?

    var onCaret: ((_ offset: Int, _ selectedBytes: Int, _ value: UInt8?) -> Void)?
    var onModifiedChange: (() -> Void)?
    var onZoom: ((Int) -> Void)?
    /// Total height / offset changed; the owner re-syncs its NSScroller.
    var onScrollMetricsChange: (() -> Void)?

    init(document: HexDocument) {
        self.document = document
        self.font = AppFonts.editor(baseFontSize)
        super.init(frame: .zero)
        document.delegate = self
        offsetDigits = max(8, String(max(1, document.byteCount) - 1, radix: 16).count)
        updateFontMetrics()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { document.undoManager }

    override func becomeFirstResponder() -> Bool { startBlink(); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate(); caretVisible = false; needsDisplay = true
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateFontMetrics() {
        ascent = font.ascender
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        charW = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: - Geometry

    private func rowCount() -> Int {
        let n = document.byteCount
        return n == 0 ? 1 : (n + bytesPerRow - 1) / bytesPerRow
    }

    private var hexX: CGFloat { leftPadding + CGFloat(offsetDigits + 2) * charW }
    /// X of hex cell `col` (0…16; an extra gap splits the two 8-byte groups).
    private func cellX(_ col: Int) -> CGFloat {
        hexX + CGFloat(col * 3 + (col >= 8 ? 1 : 0)) * charW
    }
    /// Right edge of the hex cell section (start of the draggable divider zone).
    private var hexSectionEnd: CGFloat { cellX(bytesPerRow) }
    private var asciiX: CGFloat { hexSectionEnd + 2 * charW + asciiExtraGap }

    // MARK: - Scrolling (view-owned; the view itself stays viewport-sized)

    private var scrollY: CGFloat = 0
    private var totalHeight: CGFloat { CGFloat(rowCount()) * lineHeight }
    private var maxScrollY: CGFloat { max(0, totalHeight - bounds.height) }

    var knobProportion: CGFloat { totalHeight > 0 ? min(1, bounds.height / totalHeight) : 1 }
    var scrollFraction: Double { maxScrollY > 0 ? Double(scrollY / maxScrollY) : 0 }

    func setScrollFraction(_ f: Double) { setScrollY(CGFloat(f) * maxScrollY) }
    func scrollBy(lines: Int) { setScrollY(scrollY + CGFloat(lines) * lineHeight) }
    func scrollBy(pages: Int) { setScrollY(scrollY + CGFloat(pages) * bounds.height) }

    private func setScrollY(_ y: CGFloat) {
        let clamped = min(max(0, y), maxScrollY)
        if clamped != scrollY {
            scrollY = clamped
            needsDisplay = true
        }
        onScrollMetricsChange?()
    }

    override func scrollWheel(with event: NSEvent) {
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                   : event.scrollingDeltaY * lineHeight
        setScrollY(scrollY - step)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        asciiExtraGap = min(asciiExtraGap, maxAsciiGap)
        setScrollY(scrollY)   // re-clamp and re-sync the scroller
    }

    private var visibleRows: Int {
        max(1, Int(bounds.height / lineHeight) - 1)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let n = document.byteCount
        let rows = rowCount()
        let first = max(0, Int(scrollY / lineHeight))
        let last = min(rows - 1, Int((scrollY + bounds.height) / lineHeight))
        guard n > 0, first <= last else { drawCaretIfNeeded(); return }

        let ctx = NSGraphicsContext.current!.cgContext

        for r in first...last {
            let rowStart = r * bytesPerRow
            let len = min(bytesPerRow, n - rowStart)
            let y = CGFloat(r) * lineHeight - scrollY

            if hasSelection {
                let lo = max(selLow, rowStart), hi = min(selHigh, rowStart + len)
                if hi > lo {
                    let b0 = lo - rowStart, b1 = hi - rowStart
                    let hexRect = NSRect(x: cellX(b0), y: y,
                                         width: cellX(b1 - 1) + 2 * charW - cellX(b0),
                                         height: lineHeight)
                    let asciiRect = NSRect(x: asciiX + CGFloat(b0) * charW, y: y,
                                           width: CGFloat(b1 - b0) * charW, height: lineHeight)
                    NSColor.selectedTextBackgroundColor.setFill()
                    (activePane == .hex ? hexRect : asciiRect).fill()
                    NSColor.unemphasizedSelectedTextBackgroundColor.setFill()
                    (activePane == .hex ? asciiRect : hexRect).fill()
                }
            }

            let offStr = String(format: "%0\(offsetDigits)llX", UInt64(rowStart))
            drawLine(NSAttributedString(string: offStr, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            ]), x: leftPadding, y: y, ctx: ctx)

            var hexStr = ""
            var asciiStr = ""
            var editedCols: [Int] = []
            for b in 0..<len {
                let v = document.byte(at: rowStart + b)
                if document.isEdited(rowStart + b) { editedCols.append(b) }
                hexStr += String(format: "%02X", v)
                hexStr += (b == 7) ? "  " : " "
                asciiStr.append(v >= 0x20 && v < 0x7F ? Character(UnicodeScalar(v)) : "·")
            }
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            let hexAttr = NSMutableAttributedString(string: hexStr, attributes: base)
            let asciiAttr = NSMutableAttributedString(string: asciiStr, attributes: base)
            for b in editedCols {
                hexAttr.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                     range: NSRange(location: b * 3 + (b >= 8 ? 1 : 0), length: 2))
                asciiAttr.addAttribute(.foregroundColor, value: NSColor.systemRed,
                                       range: NSRange(location: b, length: 1))
            }
            drawLine(hexAttr, x: hexX, y: y, ctx: ctx)
            drawLine(asciiAttr, x: asciiX, y: y, ctx: ctx)
        }
        drawCaretIfNeeded()
    }

    private func drawLine(_ attr: NSAttributedString, x: CGFloat, y: CGFloat, ctx: CGContext) {
        let ct = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x, y: y + ascent)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(ct, ctx)
        ctx.restoreGState()
    }

    private func drawCaretIfNeeded() {
        guard caretVisible, !hasSelection, window?.firstResponder === self else { return }
        let n = document.byteCount
        let r = min(head / bytesPerRow, rowCount() - 1)
        let col = head - r * bytesPerRow
        let y = CGFloat(r) * lineHeight - scrollY
        guard y > -lineHeight, y < bounds.height else { return }
        let hexCaretX = cellX(col) + (highNibble ? 0 : charW)
        let asciiCaretX = asciiX + CGFloat(col) * charW
        NSColor.textColor.setFill()
        NSRect(x: activePane == .hex ? hexCaretX : asciiCaretX,
               y: y + 1, width: 1, height: lineHeight - 2).fill()
        // Hollow marker on the same byte in the other pane.
        if head < n {
            NSColor.textColor.withAlphaComponent(0.45).setStroke()
            let other = activePane == .hex
                ? NSRect(x: asciiCaretX, y: y, width: charW, height: lineHeight)
                : NSRect(x: cellX(col), y: y, width: 2 * charW, height: lineHeight)
            NSBezierPath(rect: other.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    // MARK: - Caret / blink

    private func startBlink() {
        blinkTimer?.invalidate()
        caretVisible = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretVisible.toggle()
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    private func restartBlink() {
        if window?.firstResponder === self { startBlink() }
    }

    private func setSelection(anchor a: Int, head h: Int) {
        let n = document.byteCount
        anchor = max(0, min(n, a))
        head = max(0, min(n, h))
        highNibble = true
        restartBlink()
        ensureCaretVisible()
        needsDisplay = true
        reportCaret()
    }

    private func move(to newHead: Int, extend: Bool) {
        setSelection(anchor: extend ? anchor : newHead, head: newHead)
    }

    private func reportCaret() {
        let n = document.byteCount
        onCaret?(head, hasSelection ? selHigh - selLow : 0,
                 head < n ? document.byte(at: head) : nil)
    }

    /// Push the initial caret state to the status bar once wiring is complete.
    func refreshStatus() { reportCaret() }

    func goTo(offset: Int) { setSelection(anchor: offset, head: offset) }

    /// Selects a byte range (e.g. the bytes of a pixel picked in the image
    /// panel) and scrolls it into view.
    func selectRange(_ range: Range<Int>) {
        activePane = .hex
        setSelection(anchor: range.lowerBound, head: range.upperBound)
    }

    private func ensureCaretVisible() {
        guard bounds.height > 0 else { return }
        let rowTop = CGFloat(min(head / bytesPerRow, rowCount() - 1)) * lineHeight
        if rowTop < scrollY {
            setScrollY(rowTop)
        } else if rowTop + lineHeight > scrollY + bounds.height {
            setScrollY(rowTop + lineHeight - bounds.height)
        }
    }

    // MARK: - Document changes

    func hexDocumentDidChange(_ doc: HexDocument) {
        // Whole-content swaps (pixel edits re-encode the file) change the byte
        // length: re-clamp the selection, offsets, and scroll position.
        let n = document.byteCount
        anchor = min(anchor, n)
        head = min(head, n)
        offsetDigits = max(8, String(max(1, n) - 1, radix: 16).count)
        setScrollY(scrollY)
        needsDisplay = true
        reportCaret()
        onModifiedChange?()
    }

    // MARK: - Mouse (byte selection + section divider drag)

    private var draggingDivider = false
    private var dividerDragStartX: CGFloat = 0
    private var dividerDragStartGap: CGFloat = 0
    private var maxAsciiGap: CGFloat {
        max(0, bounds.width - (hexSectionEnd + 2 * charW + CGFloat(bytesPerRow) * charW + leftPadding))
    }
    private func inDividerZone(_ p: NSPoint) -> Bool {
        p.x >= hexSectionEnd && p.x < asciiX
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: hexSectionEnd, y: 0,
                             width: max(1, asciiX - hexSectionEnd), height: bounds.height),
                      cursor: .resizeLeftRight)
    }

    private func hit(_ p: NSPoint) -> (offset: Int, pane: Pane) {
        let n = document.byteCount
        let r = max(0, min(rowCount() - 1, Int(((p.y + scrollY) / lineHeight).rounded(.down))))
        let rowStart = r * bytesPerRow
        let len = max(0, min(bytesPerRow, n - rowStart))
        let pane: Pane = p.x >= asciiX - charW ? .ascii : .hex
        var col = bytesPerRow
        if pane == .ascii {
            col = Int(((p.x - asciiX) / charW).rounded(.down))
        } else {
            for b in 0..<bytesPerRow where p.x < cellX(b + 1) - charW / 2 { col = b; break }
        }
        col = max(0, min(col, len))
        return (min(rowStart + col, n), pane)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if inDividerZone(p) {
            draggingDivider = true
            dividerDragStartX = p.x
            dividerDragStartGap = asciiExtraGap
            return
        }
        let (off, pane) = hit(p)
        activePane = pane
        if event.modifierFlags.contains(.shift) { move(to: off, extend: true) }
        else { setSelection(anchor: off, head: off) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if draggingDivider {
            asciiExtraGap = min(max(0, dividerDragStartGap + (p.x - dividerDragStartX)), maxAsciiGap)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        // Manual edge autoscroll (no enclosing clip view to do it for us).
        if p.y < 0 { setScrollY(scrollY + p.y) }
        else if p.y > bounds.height { setScrollY(scrollY + (p.y - bounds.height)) }
        let (off, _) = hit(p)
        move(to: off, extend: true)
    }

    override func mouseUp(with event: NSEvent) {
        draggingDivider = false
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let extend = flags.contains(.shift)
        let cmd = flags.contains(.command)
        let n = document.byteCount

        if let special = event.specialKey {
            switch special {
            case .leftArrow:
                let target = cmd ? head - head % bytesPerRow
                                 : ((hasSelection && !extend) ? selLow : head - 1)
                move(to: target, extend: extend); return
            case .rightArrow:
                let target = cmd ? min(n, head - head % bytesPerRow + bytesPerRow)
                                 : ((hasSelection && !extend) ? selHigh : head + 1)
                move(to: target, extend: extend); return
            case .upArrow:
                move(to: cmd ? 0 : head - bytesPerRow, extend: extend); return
            case .downArrow:
                move(to: cmd ? n : head + bytesPerRow, extend: extend); return
            case .pageUp:
                move(to: head - visibleRows * bytesPerRow, extend: extend); return
            case .pageDown:
                move(to: head + visibleRows * bytesPerRow, extend: extend); return
            case .home: move(to: 0, extend: extend); return
            case .end: move(to: n, extend: extend); return
            case .tab:
                activePane = activePane == .hex ? .ascii : .hex
                highNibble = true
                needsDisplay = true
                return
            case .delete:   // Backspace: remove the selection or the byte before the caret.
                if hasSelection { let lo = selLow; document.delete(lo..<selHigh); move(to: lo, extend: false) }
                else if head > 0 { document.delete(head - 1..<head); move(to: head - 1, extend: false) }
                return
            case .deleteForward:
                if hasSelection { let lo = selLow; document.delete(lo..<selHigh); move(to: lo, extend: false) }
                else if head < n { document.delete(head..<head + 1) }
                return
            default:
                break
            }
        }

        guard !cmd, !flags.contains(.control), let chars = event.characters, !chars.isEmpty else {
            super.keyDown(with: event)
            return
        }
        if hasSelection { setSelection(anchor: selLow, head: selLow) }

        switch activePane {
        case .hex:
            for ch in chars {
                guard ch.isASCII, let d = ch.hexDigitValue else { NSSound.beep(); continue }
                typeHexDigit(UInt8(d))
            }
        case .ascii:
            let bytes = Array(chars.utf8)
            guard !bytes.contains(where: { $0 < 0x20 }) else { NSSound.beep(); return }
            typeBytes(bytes)
        }
    }

    private func typeHexDigit(_ d: UInt8) {
        // A fresh byte is inserted when typing in insert mode or at EOF; its
        // low nibble is then completed in place.
        if highNibble, insertMode || head == document.byteCount {
            document.insert([d << 4], at: head)
            highNibble = false
        } else if highNibble {
            let cur = document.byte(at: head)
            document.setBytes([d << 4 | (cur & 0x0F)], at: head)
            highNibble = false
        } else {
            let cur = document.byte(at: head)
            document.setBytes([(cur & 0xF0) | d], at: head)
            highNibble = true
            head = min(document.byteCount, head + 1)
            anchor = head
        }
        restartBlink()
        ensureCaretVisible()
        needsDisplay = true
        reportCaret()
    }

    /// ASCII typing and paste: inserts in insert mode (or at EOF), otherwise
    /// overwrites in place, clipped at EOF.
    private func typeBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let n = document.byteCount
        if insertMode || head == n {
            document.insert(bytes, at: head)
            setSelection(anchor: head + bytes.count, head: head + bytes.count)
            return
        }
        let count = min(bytes.count, n - head)
        document.setBytes(Array(bytes[0..<count]), at: head)
        setSelection(anchor: head + count, head: head + count)
        if count < bytes.count { NSSound.beep() }   // clipped at EOF
    }

    /// The in-window popup menus don't dispatch key equivalents globally, so
    /// handle the insert-mode shortcuts here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "i" {
            toggleInsertMode(nil); return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "i" {
            insertByte(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func toggleInsertMode(_ sender: Any?) {
        insertMode.toggle()
        highNibble = true
        restartBlink()
        needsDisplay = true
        reportCaret()
    }

    /// Inserts a zero byte at the caret, ready to be typed over.
    @objc func insertByte(_ sender: Any?) {
        if hasSelection { setSelection(anchor: selLow, head: selLow) }
        document.insert([0], at: head)
        highNibble = true
        setSelection(anchor: head, head: head)
    }

    // MARK: - Standard editing actions

    @objc override func selectAll(_ sender: Any?) {
        setSelection(anchor: 0, head: document.byteCount)
    }

    /// Cap pasteboard copies so Cmd-A + Cmd-C on a multi-GB file can't OOM.
    private let maxCopyBytes = 8 << 20

    @objc func copy(_ sender: Any?) {
        guard hasSelection else { return }
        guard selHigh - selLow <= maxCopyBytes else { NSSound.beep(); return }
        var out = ""
        out.reserveCapacity((selHigh - selLow) * 3)
        for i in selLow..<selHigh {
            if i > selLow { out += " " }
            out += String(format: "%02X", document.byte(at: i))
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
    }

    /// Overwrite-paste: hex pairs if the pasteboard parses as hex, else the
    /// string's UTF-8 bytes. Never grows the file.
    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        let compact = s.filter { !$0.isWhitespace }
        var bytes: [UInt8] = []
        if !compact.isEmpty, compact.count % 2 == 0,
           compact.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            var i = compact.startIndex
            while i < compact.endIndex {
                let j = compact.index(i, offsetBy: 2)
                bytes.append(UInt8(compact[i..<j], radix: 16)!)
                i = j
            }
        } else {
            bytes = Array(s.utf8)
        }
        if hasSelection {
            // Pasting over a selection replaces it in either mode.
            let lo = selLow
            document.replaceBytes(in: lo..<selHigh, with: bytes)
            setSelection(anchor: lo + bytes.count, head: lo + bytes.count)
            return
        }
        typeBytes(bytes)
    }

    @objc func deleteSelection(_ sender: Any?) {
        guard hasSelection else { NSSound.beep(); return }
        let lo = selLow
        document.delete(lo..<selHigh)
        move(to: lo, extend: false)
    }

    @objc func undo(_ sender: Any?) { document.undoManager.undo() }
    @objc func redo(_ sender: Any?) { document.undoManager.redo() }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return hasSelection && selHigh - selLow <= maxCopyBytes
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        case #selector(undo(_:)): return document.undoManager.canUndo
        case #selector(redo(_:)): return document.undoManager.canRedo
        case #selector(deleteSelection(_:)): return hasSelection
        default: return true
        }
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) { setZoom(min(3.0, zoom + 0.1)) }
    @objc func zoomOut(_ sender: Any?) { setZoom(max(0.5, zoom - 0.1)) }
    @objc func resetZoom(_ sender: Any?) { setZoom(1.0) }

    private func setZoom(_ z: CGFloat) {
        zoom = z
        font = AppFonts.editor(round(baseFontSize * z))
        updateFontMetrics()
        setScrollY(scrollY)   // clamp to the new total height
        ensureCaretVisible()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onZoom?(Int((z * 100).rounded()))
    }
}
