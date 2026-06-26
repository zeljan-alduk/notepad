import AppKit

/// Owns one Notepad window: the in-window menu bar, the scrollable text view,
/// and the status bar, laid out top-to-bottom like Windows 10 Notepad.
final class EditorWindowController: NSWindowController {
    private let menuBar = WinMenuBar()
    private let statusBar = StatusBar()
    private let scrollView = NSScrollView()
    private let textView: TextView

    private var file: MappedFile?
    private var index: LineIndex?

    private let menuBarHeight: CGFloat = 25
    private let statusBarHeight: CGFloat = 23

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Untitled - Notepad"
        window.center()
        window.setFrameAutosaveName("NotepadMain")

        self.textView = TextView(frame: .zero)
        super.init(window: window)

        let content = FlippedContainer()
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        menuBar.menuProvider = { [weak self] in self?.makeMenu(for: $0) ?? NSMenu() }
        content.addSubview(menuBar)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.documentView = textView
        content.addSubview(scrollView)

        content.addSubview(statusBar)

        textView.onScroll = { [weak self] topLine in
            // 1-based for display; column tracking arrives with the caret (M1).
            self?.statusBar.setPosition(line: topLine + 1, col: 1)
        }

        content.onLayout = { [weak self] bounds in self?.layoutContent(in: bounds) }
        layoutContent(in: content.bounds)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layoutContent(in bounds: NSRect) {
        // Flipped container: y grows downward, menu on top, status on bottom.
        menuBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: menuBarHeight)
        statusBar.frame = NSRect(x: 0, y: bounds.height - statusBarHeight,
                                 width: bounds.width, height: statusBarHeight)
        scrollView.frame = NSRect(
            x: 0, y: menuBarHeight,
            width: bounds.width,
            height: bounds.height - menuBarHeight - statusBarHeight)
    }

    // MARK: - File opening

    func open(url: URL) {
        guard let mapped = MappedFile(url: url) else {
            NSSound.beep()
            return
        }
        let idx = LineIndex(file: mapped)
        self.file = mapped
        self.index = idx
        textView.load(file: mapped, index: idx)
        idx.build()

        window?.title = "\(url.lastPathComponent) - Notepad"
        statusBar.setEncoding("UTF-8")
        scrollView.documentView?.scroll(.zero)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window!) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.open(url: url) }
        }
    }

    // MARK: - Windows-style dropdown menus

    private func makeMenu(for title: String) -> NSMenu {
        let menu = NSMenu()
        switch title {
        case "File":
            menu.addItem(withTitle: "New", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Save", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Save As...", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Exit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        case "Edit":
            for t in ["Undo", "Cut", "Copy", "Paste", "Delete", "Find...", "Replace...", "Go To...", "Select All"] {
                menu.addItem(withTitle: t, action: nil, keyEquivalent: "")
            }
        case "Format":
            menu.addItem(withTitle: "Word Wrap", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Font...", action: nil, keyEquivalent: "")
        case "View":
            menu.addItem(withTitle: "Zoom", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Status Bar", action: nil, keyEquivalent: "")
        case "Help":
            menu.addItem(withTitle: "About Notepad", action: nil, keyEquivalent: "")
        default:
            break
        }
        return menu
    }
}

/// A flipped container so child-frame math matches the top-down Windows layout,
/// with a layout hook the controller uses to re-flow on resize.
private final class FlippedContainer: NSView {
    var onLayout: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?(bounds)
    }
}
