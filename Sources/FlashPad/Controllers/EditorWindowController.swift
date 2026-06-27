import AppKit

/// Owns one FlashPad window: the in-window menu bar, the scrollable text view,
/// and the status bar, laid out top-to-bottom like Windows 10 FlashPad.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    weak var coordinator: AppDelegate?

    private let menuBar = WinMenuBar()
    private let statusBar = StatusBar()
    private let scrollView = NSScrollView()
    private let textView: TextView

    private var doc: TextDocument

    private let menuBarHeight: CGFloat = 25
    private let statusBarHeight: CGFloat = 23

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Untitled - FlashPad"
        window.center()
        window.setFrameAutosaveName("FlashPadMain")

        self.doc = TextDocument.empty()
        self.textView = TextView(document: doc)
        super.init(window: window)

        let content = FlippedContainer()
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        menuBar.menuProvider = { [weak self] in self?.makeMenu(for: $0) ?? NSMenu() }
        content.addSubview(menuBar)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Legacy (always-visible-when-needed) scrollers instead of the macOS
        // overlay style that fades out, but auto-hidden when the content fits —
        // so the horizontal bar only appears when a line is actually too wide.
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.documentView = textView
        content.addSubview(scrollView)

        content.addSubview(statusBar)

        textView.onCaret = { [weak self] line, col in
            self?.statusBar.setPosition(line: line, col: col)
        }
        textView.onModifiedChange = { [weak self] in self?.updateTitle() }
        textView.onZoom = { [weak self] pct in self?.statusBar.setZoom(pct) }
        textView.onOpenFiles = { [weak self] urls in self?.coordinator?.openDropped(urls) }

        content.onLayout = { [weak self] bounds in self?.layoutContent(in: bounds) }
        layoutContent(in: content.bounds)

        window.delegate = self
        window.makeFirstResponder(textView)
        reflectDocument()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.controllerDidClose(self)
    }

    /// Prompt to save unsaved changes before closing (FlashPad behaviour).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard doc.isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return saveSynchronously()
        case .alertSecondButtonReturn: return true    // discard
        default:                       return false   // cancel
        }
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) {
        if let url = doc.fileURL { performSave(to: url, as: doc.encoding) }
        else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Untitled.txt"
        let picker = encodingPicker(selected: doc.encoding)
        panel.accessoryView = picker.view
        panel.beginSheetModal(for: window!) { [weak self] resp in
            if resp == .OK, let url = panel.url {
                self?.performSave(to: url, as: picker.encoding())
            }
        }
    }

    /// Builds a "Encoding:" popup accessory for the save panel.
    private func encodingPicker(selected: FileEncoding) -> (view: NSView, encoding: () -> FileEncoding) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 40))
        let label = NSTextField(labelWithString: "Encoding:")
        label.frame = NSRect(x: 12, y: 10, width: 70, height: 20)
        label.alignment = .right
        let popup = NSPopUpButton(frame: NSRect(x: 88, y: 6, width: 200, height: 26))
        let order: [FileEncoding] = [.utf8, .utf8BOM, .utf16LE, .utf16BE, .ansi]
        popup.addItems(withTitles: order.map { $0.menuTitle })
        popup.selectItem(at: order.firstIndex(of: selected) ?? 0)
        container.addSubview(label); container.addSubview(popup)
        return (container, { order[popup.indexOfSelectedItem] })
    }

    @discardableResult
    private func performSave(to url: URL, as encoding: FileEncoding) -> Bool {
        do {
            try doc.save(to: url, as: encoding)
            reflectDocument()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t save “\(url.lastPathComponent)”."
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
    }

    /// Synchronous save used by the close prompt; returns false to cancel close.
    private func saveSynchronously() -> Bool {
        let url: URL
        var encoding = doc.encoding
        if let u = doc.fileURL {
            url = u
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Untitled.txt"
            let picker = encodingPicker(selected: doc.encoding)
            panel.accessoryView = picker.view
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            url = u
            encoding = picker.encoding()
        }
        return performSave(to: url, as: encoding)
    }

    private var displayName: String { doc.fileURL?.lastPathComponent ?? "Untitled" }

    private func updateTitle() {
        let mark = doc.isModified ? "*" : ""
        window?.title = "\(mark)\(displayName) - FlashPad"
    }

    /// Reflect the current document's format in the status bar + title.
    private func reflectDocument() {
        statusBar.setEncoding(doc.encodingLabel)
        statusBar.setLineEnding(doc.lineEndingLabel)
        statusBar.setPosition(line: 1, col: 1)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layoutContent(in bounds: NSRect) {
        // Flipped container: y grows downward, menu on top, status on bottom.
        let statusH = statusBarVisible ? statusBarHeight : 0
        menuBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: menuBarHeight)
        statusBar.frame = NSRect(x: 0, y: bounds.height - statusH,
                                 width: bounds.width, height: statusBarHeight)
        scrollView.frame = NSRect(
            x: 0, y: menuBarHeight,
            width: bounds.width,
            height: bounds.height - menuBarHeight - statusH)
    }

    // MARK: - File opening

    func open(url: URL, scopedURL: URL? = nil) {
        // Detect encoding (transcoding non-UTF-8 to a temp UTF-8 file) and index
        // on a background thread, so the line model is correct before the view
        // ever draws and the UI stays responsive on huge files.
        window?.title = "Opening… - FlashPad"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let opened = prepareForReading(url) else {
                scopedURL?.stopAccessingSecurityScopedResource()
                DispatchQueue.main.async { NSSound.beep(); self?.updateTitle() }
                return
            }
            let idx = LineIndex(file: opened.mapped)
            idx.buildSynchronously()
            let lineEnding = detectLineEnding(opened.mapped, from: opened.contentStart)
            DispatchQueue.main.async {
                guard let self else { scopedURL?.stopAccessingSecurityScopedResource(); return }
                let doc = TextDocument(file: opened.mapped, index: idx, url: url,
                                       encoding: opened.encoding, lineEnding: lineEnding,
                                       contentStart: opened.contentStart, tempURL: opened.tempURL,
                                       scopedURL: scopedURL)
                self.doc = doc
                self.textView.setDocument(doc)
                self.reflectDocument()
                self.coordinator?.noteRecent(url)
            }
        }
    }

    // MARK: - Quick wins

    @objc func insertTimeDate(_ sender: Any?) {
        let now = Date()
        let time = DateFormatter(); time.timeStyle = .short; time.dateStyle = .none
        let date = DateFormatter(); date.dateStyle = .short; date.timeStyle = .none
        textView.insertAtCaret("\(time.string(from: now)) \(date.string(from: now))")
    }

    private var statusBarVisible = true
    @objc func toggleStatusBar(_ sender: Any?) {
        statusBarVisible.toggle()
        statusBar.isHidden = !statusBarVisible
        if let content = window?.contentView { layoutContent(in: content.bounds) }
    }

    @objc func runPageLayout(_ sender: Any?) {
        NSApp.runPageLayout(sender)
    }

    @objc func printDocument(_ sender: Any?) {
        let printView = PrintTextView(document: doc, baseFont: textView.currentBaseFont)
        let op = NSPrintOperation(view: printView)
        op.jobTitle = displayName
        op.runModal(for: window!, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Find / Replace / Go To

    private lazy var findPanel = FindPanelController()

    @objc func performFindPanel(_ sender: Any?) {
        findPanel.present(for: textView, focusReplace: false)
    }
    @objc func performReplacePanel(_ sender: Any?) {
        findPanel.present(for: textView, focusReplace: true)
    }
    @objc func findNextCommand(_ sender: Any?) { repeatFind(forward: true) }
    @objc func findPreviousCommand(_ sender: Any?) { repeatFind(forward: false) }

    private func repeatFind(forward: Bool) {
        // Use the panel's term, or the current selection if the panel is unused.
        var term = findPanel.lastTerm
        if term.isEmpty { term = textView.selectionText }
        guard !term.isEmpty else { NSSound.beep(); return }
        if !textView.findNext(term, caseSensitive: findPanel.caseSensitive, forward: forward) {
            NSSound.beep()
        }
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        let want = !textView.wrapEnabled
        if !textView.setWrap(want), want {
            let alert = NSAlert()
            alert.messageText = "Word Wrap is unavailable for very large files."
            alert.informativeText = "Files with more than \(textView.wrapLineCap) lines stay unwrapped so the app remains responsive."
            alert.runModal()
        }
    }

    @objc func openFontPanel(_ sender: Any?) {
        let fm = NSFontManager.shared
        fm.setSelectedFont(textView.currentBaseFont, isMultiple: false)
        fm.orderFrontFontPanel(self)
        window?.makeFirstResponder(textView)   // so changeFont: reaches the view
    }

    @objc func performGoToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to line:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn, let n = Int(field.stringValue) {
            textView.goToLine(n)
            window?.makeFirstResponder(textView)
        }
    }

    /// Whether this window is a pristine untitled buffer (reused instead of
    /// spawning a second empty window when opening the first file).
    var isPristine: Bool { doc.fileURL == nil && !doc.isModified }

    // MARK: - Windows-style dropdown menus

    private func makeMenu(for title: String) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            if let target { item.target = target }
        }
        switch title {
        case "File":
            add("New", #selector(AppDelegate.newDocument(_:)), "n", target: coordinator)
            add("Open...", #selector(AppDelegate.openDocument(_:)), "o", target: coordinator)
            add("New Window", #selector(AppDelegate.newDocument(_:)), target: coordinator)
            let recent = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
            recent.submenu = coordinator?.makeRecentMenu()
            menu.addItem(.separator())
            add("Save", #selector(saveDocument(_:)), "s", target: self)
            add("Save As...", #selector(saveDocumentAs(_:)), target: self)
            menu.addItem(.separator())
            add("Page Setup...", #selector(runPageLayout(_:)), target: self)
            add("Print...", #selector(printDocument(_:)), "p", target: self)
            menu.addItem(.separator())
            add("Exit", #selector(NSApplication.terminate(_:)), target: NSApp)
        case "Edit":
            // nil targets route up the responder chain to the focused TextView.
            add("Undo", #selector(TextView.undo(_:)), "z")
            add("Redo", #selector(TextView.redo(_:)), "Z")
            menu.addItem(.separator())
            add("Cut", #selector(NSText.cut(_:)), "x")
            add("Copy", #selector(NSText.copy(_:)), "c")
            add("Paste", #selector(NSText.paste(_:)), "v")
            menu.addItem(.separator())
            add("Find...", #selector(performFindPanel(_:)), "f", target: self)
            add("Find Next", #selector(findNextCommand(_:)), "g", target: self)
            add("Replace...", #selector(performReplacePanel(_:)), target: self)
            add("Go To...", #selector(performGoToLine(_:)), "l", target: self)
            menu.addItem(.separator())
            add("Select All", #selector(NSText.selectAll(_:)), "a")
            add("Time/Date", #selector(insertTimeDate(_:)), target: self)
        case "Format":
            let wrap = menu.addItem(withTitle: "Word Wrap", action: #selector(toggleWordWrap(_:)), keyEquivalent: "")
            wrap.target = self
            wrap.state = textView.wrapEnabled ? .on : .off
            add("Font...", #selector(openFontPanel(_:)), target: self)
        case "View":
            add("Zoom In", #selector(TextView.zoomIn(_:)), "+")
            add("Zoom Out", #selector(TextView.zoomOut(_:)), "-")
            add("Restore Default Zoom", #selector(TextView.resetZoom(_:)), "0")
            menu.addItem(.separator())
            let sb = menu.addItem(withTitle: "Status Bar", action: #selector(toggleStatusBar(_:)), keyEquivalent: "")
            sb.target = self
            sb.state = statusBarVisible ? .on : .off
        case "Help":
            add("About FlashPad", #selector(AppDelegate.showAbout(_:)), target: coordinator)
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
