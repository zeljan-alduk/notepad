import AppKit

/// Owns one hex-editor window: the in-window menu strip, a split view holding
/// the hex editor and (for image files) the pinned image inspector, and the
/// status bar. Binary files (NUL bytes in the head) open here instead of the
/// text editor, which would mangle them through the ANSI path.
final class HexWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    weak var coordinator: AppDelegate?

    private let menuBar = WinMenuBar(titles: ["File", "Edit", "View", "Help"])
    private let statusBar = StatusBar()
    private let split = NSSplitView()
    private let hexPane = FlippedHexContainer()
    private let vScroller = NSScroller()
    private let hexView: HexView
    private let doc: HexDocument

    // Image preview: shown when the bytes decode as an image, pinned to the
    // right of the scrolling hex, refreshed (debounced) as bytes are edited.
    // The split-view divider lets the user resize hex vs. image sections.
    private let imagePanel = ImageInspector()
    private var imagePanelVisible = false
    private var previewGeneration = 0
    private let previewQueue = DispatchQueue(label: "flashpad.image-preview", qos: .utility)

    private let menuBarHeight: CGFloat = 25
    private let statusBarHeight: CGFloat = 23
    private let defaultPanelWidth: CGFloat = 320

    init(file: MappedFile, url: URL, scopedURL: URL? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()
        window.contentMinSize = NSSize(width: 560, height: 320)

        self.doc = HexDocument(file: file, url: url, scopedURL: scopedURL)
        self.hexView = HexView(document: doc)
        super.init(window: window)

        let content = FlippedHexContainer()
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        menuBar.menuProvider = { [weak self] in self?.makeMenu(for: $0) ?? NSMenu() }
        content.addSubview(menuBar)

        hexPane.addSubview(hexView)
        vScroller.scrollerStyle = .legacy
        vScroller.controlSize = .regular
        vScroller.target = self
        vScroller.action = #selector(scrollerAction(_:))
        hexPane.addSubview(vScroller)
        hexPane.onLayout = { [weak self] bounds in self?.layoutHexPane(in: bounds) }

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(hexPane)
        imagePanel.isHidden = true
        split.addArrangedSubview(imagePanel)
        content.addSubview(split)

        content.addSubview(statusBar)

        statusBar.setEncoding("Binary (hex)")
        statusBar.setLineEnding(Self.sizeLabel(file.count))
        hexView.onCaret = { [weak self] off, selected, value in
            guard let self else { return }
            var text = String(format: "Offset 0x%llX (%lld)", UInt64(off), Int64(off))
            if selected > 0 { text += " — \(selected) bytes selected" }
            else if let value { text += String(format: " — %02X (%d)", value, value) }
            if self.hexView.insertMode { text += "  [INS]" }
            self.statusBar.setPositionText(text)
            // Reverse sync: a caret on a pixel's bytes reveals it on the canvas.
            if self.imagePanelVisible, selected == 0 {
                self.imagePanel.revealPixel(forByte: off)
            }
        }
        hexView.onModifiedChange = { [weak self] in
            guard let self else { return }
            self.updateTitle()
            self.statusBar.setLineEnding(Self.sizeLabel(self.doc.byteCount))
            self.scheduleImagePreviewRefresh()
        }
        imagePanel.onApplyPixels = { [weak self] bitmap, typeID in
            self?.applyPixelEdits(bitmap, typeID: typeID)
        }
        // Picking a pixel selects its bytes in the hex view (formats that
        // store pixels raw; a compressed pixel has no byte address).
        imagePanel.onPixelPicked = { [weak self] _, _, byteRange in
            if let byteRange { self?.hexView.selectRange(byteRange) }
        }
        hexView.onZoom = { [weak self] pct in self?.statusBar.setZoom(pct) }
        hexView.onScrollMetricsChange = { [weak self] in self?.syncScroller() }

        content.onLayout = { [weak self] bounds in self?.layoutContent(in: bounds) }
        layoutContent(in: content.bounds)

        window.delegate = self
        window.makeFirstResponder(hexView)
        hexView.refreshStatus()
        updateTitle()
        scheduleImagePreviewRefresh(debounce: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Human size plus the exact byte count, so single-byte inserts/deletes
    /// are visible immediately.
    private static func sizeLabel(_ bytes: Int) -> String {
        let human = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let exact = NumberFormatter.localizedString(from: NSNumber(value: bytes), number: .decimal)
        return "\(human) (\(exact) B)"
    }

    private var displayName: String { doc.fileURL?.lastPathComponent ?? "Untitled" }

    private func updateTitle() {
        let mark = doc.isModified ? "*" : ""
        window?.title = "\(mark)\(displayName) - FlashPad"
    }

    // MARK: - Layout

    private func layoutContent(in bounds: NSRect) {
        let statusH = statusBarVisible ? statusBarHeight : 0
        menuBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: menuBarHeight)
        statusBar.frame = NSRect(x: 0, y: bounds.height - statusH,
                                 width: bounds.width, height: statusBarHeight)
        split.frame = NSRect(x: 0, y: menuBarHeight,
                             width: bounds.width,
                             height: bounds.height - menuBarHeight - statusH)
    }

    private func layoutHexPane(in bounds: NSRect) {
        let sw = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        hexView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - sw), height: bounds.height)
        vScroller.frame = NSRect(x: bounds.width - sw, y: 0, width: sw, height: bounds.height)
        syncScroller()
    }

    // MARK: - Scroller plumbing

    private func syncScroller() {
        vScroller.knobProportion = hexView.knobProportion
        vScroller.doubleValue = hexView.scrollFraction
        vScroller.isEnabled = hexView.knobProportion < 1
    }

    @objc private func scrollerAction(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementPage: hexView.scrollBy(pages: -1)
        case .incrementPage: hexView.scrollBy(pages: 1)
        case .decrementLine: hexView.scrollBy(lines: -3)
        case .incrementLine: hexView.scrollBy(lines: 3)
        default: hexView.setScrollFraction(sender.doubleValue)
        }
    }

    // MARK: - Split view (resizable hex / image sections)

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 280)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 160)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // Keep the image panel's width on window resize; the hex side flexes.
        guard imagePanelVisible, !imagePanel.isHidden else {
            splitView.adjustSubviews()
            return
        }
        let panelW = min(imagePanel.frame.width, max(160, splitView.bounds.width - 280))
        let hexW = splitView.bounds.width - panelW - splitView.dividerThickness
        hexPane.frame = NSRect(x: 0, y: 0, width: hexW, height: splitView.bounds.height)
        imagePanel.frame = NSRect(x: hexW + splitView.dividerThickness, y: 0,
                                  width: panelW, height: splitView.bounds.height)
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.hexControllerDidClose(self)
    }

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
        case .alertSecondButtonReturn: return true
        default:                       return false
        }
    }

    // MARK: - Image preview

    /// Rebuilds the image preview from the patched bytes on a background queue.
    /// The generation counter both debounces bursts of keystrokes and drops
    /// stale results that finish after a newer edit.
    private func scheduleImagePreviewRefresh(debounce: TimeInterval = 0.25) {
        previewGeneration += 1
        let gen = previewGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce) { [weak self] in
            guard let self, gen == self.previewGeneration else { return }
            guard let data = self.doc.patchedData(maxBytes: ImagePreview.maxSourceBytes) else { return }
            self.previewQueue.async { [weak self] in
                let result = ImagePreview.decode(data)
                DispatchQueue.main.async {
                    guard let self, gen == self.previewGeneration else { return }
                    self.applyPreview(result)
                }
            }
        }
    }

    private func applyPreview(_ result: ImagePreview.Result) {
        // Once the panel is up, keep it (with a diagnostic) even if an edit
        // breaks the magic bytes — hiding it mid-edit would be disorienting.
        if result.isImage || imagePanelVisible {
            imagePanel.set(result: result)
        }
        if result.isImage, !imagePanelVisible {
            imagePanelVisible = true
            imagePanel.isHidden = false
            split.adjustSubviews()
            split.setPosition(max(280, split.bounds.width - defaultPanelWidth), ofDividerAt: 0)
        }
    }

    /// Re-encodes the pixel-edited bitmap in the file's format and swaps the
    /// result into the document as one undoable step. The normal change
    /// pipeline then refreshes the hex rows, title, size, and preview.
    private func applyPixelEdits(_ bitmap: PixelBitmap, typeID: String?) {
        previewQueue.async { [weak self] in
            let encoded = ImagePreview.encode(bitmap, typeID: typeID)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data = encoded else {
                    self.presentError(title: "Couldn’t re-encode the image.",
                                      detail: "The pixel edits were kept in the panel; the file bytes are unchanged.")
                    return
                }
                do {
                    try self.doc.replaceContents(with: data)
                } catch {
                    self.presentError(title: "Couldn’t apply pixel edits.", detail: "\(error)")
                }
            }
        }
    }

    private func presentError(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: - Saving

    @objc func saveDocument(_ sender: Any?) {
        if let url = doc.fileURL { performSave(to: url) }
        else { saveDocumentAs(sender) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? "Untitled.bin"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.performSave(to: url) }
        }
    }

    @discardableResult
    private func performSave(to url: URL) -> Bool {
        do {
            try doc.save(to: url)
            updateTitle()
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t save “\(url.lastPathComponent)”."
            alert.informativeText = "\(error)"
            alert.runModal()
            return false
        }
    }

    private func saveSynchronously() -> Bool {
        if let url = doc.fileURL { return performSave(to: url) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return performSave(to: url)
    }

    // MARK: - Go to offset

    @objc func performGoToOffset(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to offset (decimal or 0x hex):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        let offset: Int?
        if raw.lowercased().hasPrefix("0x") { offset = Int(raw.dropFirst(2), radix: 16) }
        else { offset = Int(raw) ?? Int(raw, radix: 16) }
        if let offset {
            hexView.goTo(offset: offset)
            window?.makeFirstResponder(hexView)
        } else {
            NSSound.beep()
        }
    }

    private var statusBarVisible = true
    @objc func toggleStatusBar(_ sender: Any?) {
        statusBarVisible.toggle()
        statusBar.isHidden = !statusBarVisible
        if let content = window?.contentView { layoutContent(in: content.bounds) }
    }

    // MARK: - Windows-style dropdown menus

    private func makeMenu(for title: String) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, _ key: String = "", target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            if let target { item.target = target }
        }
        switch title {
        case "File":
            add("New Window", #selector(AppDelegate.newDocument(_:)), "n", target: coordinator)
            add("Open...", #selector(AppDelegate.openDocument(_:)), "o", target: coordinator)
            let recent = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
            recent.submenu = coordinator?.makeRecentMenu()
            menu.addItem(.separator())
            add("Save", #selector(saveDocument(_:)), "s", target: self)
            add("Save As...", #selector(saveDocumentAs(_:)), target: self)
            menu.addItem(.separator())
            add("Exit", #selector(NSApplication.terminate(_:)), target: NSApp)
        case "Edit":
            add("Undo", #selector(HexView.undo(_:)), "z", target: hexView)
            add("Redo", #selector(HexView.redo(_:)), "Z", target: hexView)
            menu.addItem(.separator())
            add("Copy as Hex", #selector(HexView.copy(_:)), "c", target: hexView)
            add("Paste", #selector(HexView.paste(_:)), "v", target: hexView)
            menu.addItem(.separator())
            let ins = menu.addItem(withTitle: "Insert Mode",
                                   action: #selector(HexView.toggleInsertMode(_:)), keyEquivalent: "i")
            ins.target = hexView
            ins.state = hexView.insertMode ? .on : .off
            let insByte = menu.addItem(withTitle: "Insert Byte at Caret",
                                       action: #selector(HexView.insertByte(_:)), keyEquivalent: "I")
            insByte.target = hexView
            add("Delete Selected Bytes", #selector(HexView.deleteSelection(_:)), target: hexView)
            menu.addItem(.separator())
            add("Select All", #selector(HexView.selectAll(_:)), "a", target: hexView)
            add("Go to Offset...", #selector(performGoToOffset(_:)), "l", target: self)
        case "View":
            add("Zoom In", #selector(HexView.zoomIn(_:)), "+", target: hexView)
            add("Zoom Out", #selector(HexView.zoomOut(_:)), "-", target: hexView)
            add("Restore Default Zoom", #selector(HexView.resetZoom(_:)), "0", target: hexView)
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

/// Flipped, top-down layout container (same pattern as the editor window),
/// with a layout hook so owners can re-flow children on resize.
final class FlippedHexContainer: NSView {
    var onLayout: ((NSRect) -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?(bounds)
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?(bounds)
    }
}
