import AppKit

/// Read-only viewport renderer (Milestone 0).
///
/// The view's frame is sized to the whole document (lineCount × lineHeight), but
/// `draw(_:)` only builds and paints the lines that intersect the dirty rect —
/// typically ~50. That is what makes scrolling a multi-GB file cheap.
final class TextView: NSView {
    private(set) var file: MappedFile?
    private(set) var index: LineIndex?

    let font: NSFont
    let lineHeight: CGFloat
    private let textColor = NSColor.black
    private let leftPadding: CGFloat = 4

    /// Reports the line under the top of the viewport (for the status bar).
    var onScroll: ((_ topLine: Int) -> Void)?

    override init(frame frameRect: NSRect) {
        // Windows 10 Notepad's default text font is Consolas; fall back to Menlo.
        let f = NSFont(name: "Consolas", size: 15)
            ?? NSFont(name: "Menlo", size: 14)
            ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        self.font = f
        self.lineHeight = ceil(f.ascender - f.descender + f.leading) + 2
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }   // y grows downward, so line N sits at N*lineHeight
    override var isOpaque: Bool { true }

    func load(file: MappedFile, index: LineIndex) {
        self.file = file
        self.index = index
        index.onProgress = { [weak self] in self?.documentDidGrow() }
        documentDidGrow()
    }

    /// Re-sizes the document view as the background index discovers more lines.
    private func documentDidGrow() {
        guard let index else { return }
        let height = max(CGFloat(index.lineCount) * lineHeight, bounds.height)
        // Width is a generous placeholder until we track the longest line (M2).
        let width: CGFloat = 4000
        if frame.size.height != height || frame.size.width != width {
            setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        guard let file, let index, file.count >= 0 else { return }
        let total = index.lineCount
        guard total > 0 else { return }

        let firstLine = max(0, Int((dirtyRect.minY / lineHeight).rounded(.down)))
        let lastLine = min(total - 1, Int((dirtyRect.maxY / lineHeight).rounded(.down)))
        guard firstLine <= lastLine else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        var offset = index.byteOffset(forLine: firstLine)
        for line in firstLine...lastLine {
            let end = index.lineEnd(fromStart: offset)
            // Drop a trailing CR so CRLF files don't render a stray glyph.
            var displayEnd = end
            if displayEnd > offset, file.byte(at: displayEnd - 1) == 0x0D {
                displayEnd -= 1
            }
            let text = file.string(from: offset, to: displayEnd)
            let y = CGFloat(line) * lineHeight
            (text as NSString).draw(at: CGPoint(x: leftPadding, y: y), withAttributes: attrs)

            if end >= file.count { break }
            offset = end + 1
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clip = enclosingScrollView?.contentView {
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
            clip.postsBoundsChangedNotifications = true
        }
    }

    @objc private func boundsChanged() {
        let topY = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        onScroll?(max(0, Int((topY / lineHeight).rounded(.down))))
    }
}
