import AppKit

/// The Win10 (1809+) Notepad status bar: position on the left, then zoom,
/// line-ending style, and encoding on the right.
final class StatusBar: NSView {
    private let position = NSTextField(labelWithString: "Ln 1, Col 1")
    private let zoom = NSTextField(labelWithString: "100%")
    private let lineEnding = NSTextField(labelWithString: "Windows (CRLF)")
    private let encoding = NSTextField(labelWithString: "UTF-8")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateBackground()

        let chromeFont = AppFonts.ui(12)
        for field in [position, zoom, lineEnding, encoding] {
            field.font = chromeFont
            field.textColor = .secondaryLabelColor
            field.backgroundColor = .clear
            field.isBordered = false
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
        line.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        line.stroke()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        position.sizeToFit()
        position.frame.origin = NSPoint(x: 8, y: (h - position.frame.height) / 2)

        // Right-aligned cells, fixed-ish widths separated by dividers.
        var x = bounds.maxX
        for field in [encoding, lineEnding, zoom] {
            field.sizeToFit()
            let w = max(field.frame.width, 70)
            x -= w + 12
            field.frame = NSRect(x: x, y: (h - field.frame.height) / 2,
                                 width: w, height: field.frame.height)
        }
    }

    func setPosition(line: Int, col: Int) {
        position.stringValue = "Ln \(line), Col \(col)"
        needsLayout = true
    }

    func setEncoding(_ text: String) { encoding.stringValue = text; needsLayout = true }
    func setLineEnding(_ text: String) { lineEnding.stringValue = text; needsLayout = true }
    func setZoom(_ percent: Int) { zoom.stringValue = "\(percent)%"; needsLayout = true }
}
