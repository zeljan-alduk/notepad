import AppKit

/// A Windows-style in-window menu strip: File / Edit / Format / View / Help.
/// On Windows the menu lives inside the window (not a global bar), which is the
/// single most recognizable part of the Notepad look.
final class WinMenuBar: NSView {
    private let titles = ["File", "Edit", "Format", "View", "Help"]
    private var buttons: [NSButton] = []

    /// Builds the dropdown for a given top-level title. Supplied by the controller.
    var menuProvider: ((String) -> NSMenu)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let chromeFont = NSFont(name: "Segoe UI", size: 13)
            ?? NSFont.systemFont(ofSize: 13)

        var x: CGFloat = 0
        for title in titles {
            let b = NSButton(title: title, target: self, action: #selector(openMenu(_:)))
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.font = chromeFont
            b.contentTintColor = .black
            let width = (title as NSString).size(withAttributes: [.font: chromeFont]).width + 18
            b.frame = NSRect(x: x, y: 0, width: width, height: 24)
            b.autoresizingMask = [.maxXMargin]
            addSubview(b)
            buttons.append(b)
            x += width
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        // Thin separator under the menu bar, like Win10.
        NSColor(white: 0.85, alpha: 1).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
        line.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        line.stroke()
    }

    @objc private func openMenu(_ sender: NSButton) {
        guard let menu = menuProvider?(sender.title) else { return }
        let origin = NSPoint(x: 0, y: sender.bounds.maxY)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }
}
