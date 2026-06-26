import AppKit

/// A read-only view used only for printing. It paginates by line and draws only
/// the lines on the page being rendered, so printing streams from the piece
/// table instead of materializing the whole document.
final class PrintTextView: NSView {
    private let document: TextDocument
    private let font: NSFont
    private let lineHeight: CGFloat
    private var linesPerPage = 1

    init(document: TextDocument, baseFont: NSFont) {
        self.document = document
        self.font = NSFont(descriptor: baseFont.fontDescriptor, size: 10) ?? baseFont
        self.lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let w = info.paperSize.width - info.leftMargin - info.rightMargin
        let h = info.paperSize.height - info.topMargin - info.bottomMargin
        linesPerPage = max(1, Int(h / lineHeight))
        let total = document.pieceTable.lineCount
        let pages = max(1, (total + linesPerPage - 1) / linesPerPage)
        setFrameSize(NSSize(width: w, height: CGFloat(pages * linesPerPage) * lineHeight))
        range.pointee = NSRange(location: 1, length: pages)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat((page - 1) * linesPerPage) * lineHeight,
               width: frame.width, height: CGFloat(linesPerPage) * lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        let pt = document.pieceTable
        let total = pt.lineCount
        guard total > 0 else { return }

        let first = max(0, Int((dirtyRect.minY / lineHeight).rounded(.down)))
        let last = min(total - 1, Int((dirtyRect.maxY / lineHeight).rounded(.down)))
        guard first <= last else { return }

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        for line in first...last {
            let s = pt.lineStart(line)
            let e = min(pt.lineEnd(line), s + 20_000)
            let text = pt.string(in: s..<e)
            (text as NSString).draw(at: CGPoint(x: 2, y: CGFloat(line) * lineHeight), withAttributes: attrs)
        }
    }
}
