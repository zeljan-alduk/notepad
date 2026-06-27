import AppKit

enum LaunchClock { static var start = Date() }

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One controller per open window. Each owns its own document, so windows
    /// share only the AppKit frameworks — a new window costs a few MB + its file.
    private var controllers: [EditorWindowController] = []

    private lazy var aboutController = AboutWindowController()
    private let openRecentMenu = NSMenu(title: "Open Recent")
    private let recentKey = "RecentFiles"
    private let maxRecent = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the Dock icon programmatically so it shows in every run mode
        // (bare binary, swift run, or .app) regardless of Launch Services cache.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
        installGlobalMenu()

        let first = newWindow()

        // Open a file passed on the command line, if any.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            first.open(url: URL(fileURLWithPath: path))
        }

        NSApp.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["NOTEPAD_TIMING"] != nil {
            let ms = Date().timeIntervalSince(LaunchClock.start) * 1000
            let mono = NSFont(name: "CascadiaMono-Regular", size: 12) != nil
            let ui = NSFont(name: "Selawik-Regular", size: 12) != nil
            FileHandle.standardError.write(Data(String(format: "STARTUP %.1f ms  fonts: cascadia=%@ selawik=%@\n",
                ms, mono ? "yes" : "no", ui ? "yes" : "no").utf8))
        }
    }

    @discardableResult
    func newWindow() -> EditorWindowController {
        let controller = EditorWindowController()
        controller.coordinator = self
        controllers.append(controller)
        if let w = controller.window, controllers.count > 1 {
            w.cascadeTopLeft(from: NSPoint(x: 40, y: 40))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    func controllerDidClose(_ controller: EditorWindowController) {
        controllers.removeAll { $0 === controller }
    }

    /// File ▸ New / ⌘N — opens a fresh window (a new "instance").
    @objc func newDocument(_ sender: Any?) {
        newWindow()
    }

    /// File ▸ Open / ⌘O — reuses a pristine front window, else opens a new one.
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            for url in panel.urls { self.open(url: url) }
        }
    }

    private func open(url: URL, scopedURL: URL? = nil) {
        if let front = frontController(), front.isPristine {
            front.open(url: url, scopedURL: scopedURL)
        } else {
            newWindow().open(url: url, scopedURL: scopedURL)
        }
    }

    private func frontController() -> EditorWindowController? {
        if let key = NSApp.keyWindow,
           let c = controllers.first(where: { $0.window === key }) { return c }
        return controllers.last
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url: url) }
    }

    /// Files dropped onto a window.
    func openDropped(_ urls: [URL]) {
        for url in urls { open(url: url) }
    }

    @objc func showAbout(_ sender: Any?) { aboutController.present() }

    // MARK: - Recent files (security-scoped bookmarks, so they reopen under sandbox)

    private var recentBookmarks: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    func noteRecent(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        var arr = recentBookmarks
        arr.removeAll { resolveBookmark($0)?.url.path == url.path }   // dedupe
        arr.insert(data.base64EncodedString(), at: 0)
        if arr.count > maxRecent { arr = Array(arr.prefix(maxRecent)) }
        UserDefaults.standard.set(arr, forKey: recentKey)
        rebuildRecentMenu()
    }

    private func resolveBookmark(_ b64: String) -> (url: URL, stale: Bool)? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Builds a fresh "Open Recent" submenu (for the in-window File menu).
    func makeRecentMenu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        populateRecent(into: menu)
        return menu
    }

    private func populateRecent(into menu: NSMenu) {
        menu.removeAllItems()
        let bookmarks = recentBookmarks
        for b64 in bookmarks {
            guard let (url, _) = resolveBookmark(b64) else { continue }
            let item = menu.addItem(withTitle: url.lastPathComponent,
                                    action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = b64
        }
        if !bookmarks.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
    }

    private func rebuildRecentMenu() { populateRecent(into: openRecentMenu) }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        guard let b64 = sender.representedObject as? String,
              let (url, _) = resolveBookmark(b64) else { NSSound.beep(); return }
        // Start security-scoped access; the document stops it when it closes.
        let scoped = url.startAccessingSecurityScopedResource() ? url : nil
        open(url: url, scopedURL: scoped)
    }

    @objc private func clearRecent(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: recentKey)
        rebuildRecentMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Minimal macOS global menu — only what the OS needs (Quit/Hide). The
    /// visible FlashPad menu lives inside the window, Windows-style.
    private func installGlobalMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FlashPad", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FlashPad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FlashPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File + Edit carry the key equivalents; macOS dispatches these to the
        // first responder (the focused TextView) automatically.
        let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newItem = fileMenu.addItem(withTitle: "New Window", action: #selector(newDocument(_:)), keyEquivalent: "n")
        newItem.target = self
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.target = self
        let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = openRecentMenu
        rebuildRecentMenu()
        fileMenu.addItem(.separator())
        // nil target → routed to the key window's EditorWindowController.
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Page Setup…", action: #selector(EditorWindowController.runPageLayout(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Print…", action: #selector(EditorWindowController.printDocument(_:)), keyEquivalent: "p")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // nil target → key window's EditorWindowController (responder chain).
        editMenu.addItem(withTitle: "Find…", action: #selector(EditorWindowController.performFindPanel(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find Next", action: #selector(EditorWindowController.findNextCommand(_:)), keyEquivalent: "g")
        let findPrev = editMenu.addItem(withTitle: "Find Previous", action: #selector(EditorWindowController.findPreviousCommand(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        let replace = editMenu.addItem(withTitle: "Replace…", action: #selector(EditorWindowController.performReplacePanel(_:)), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(withTitle: "Go to Line…", action: #selector(EditorWindowController.performGoToLine(_:)), keyEquivalent: "l")
        editMenu.addItem(.separator())
        let f5 = String(UnicodeScalar(UInt16(NSF5FunctionKey))!)
        let timeDate = editMenu.addItem(withTitle: "Time/Date",
                                        action: #selector(EditorWindowController.insertTimeDate(_:)), keyEquivalent: f5)
        timeDate.keyEquivalentModifierMask = NSEvent.ModifierFlags.function
        editItem.submenu = editMenu

        let formatItem = NSMenuItem(); mainMenu.addItem(formatItem)
        let formatMenu = NSMenu(title: "Format")
        formatMenu.addItem(withTitle: "Word Wrap", action: #selector(EditorWindowController.toggleWordWrap(_:)), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Font…", action: #selector(EditorWindowController.openFontPanel(_:)), keyEquivalent: "")
        formatItem.submenu = formatMenu

        let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(TextView.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(TextView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Restore Default Zoom", action: #selector(TextView.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Status Bar", action: #selector(EditorWindowController.toggleStatusBar(_:)), keyEquivalent: "")
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
