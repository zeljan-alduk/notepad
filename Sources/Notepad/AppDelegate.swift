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
            FileHandle.standardError.write(Data(String(format: "STARTUP %.1f ms\n", ms).utf8))
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

    private func open(url: URL) {
        if let front = frontController(), front.isPristine {
            front.open(url: url)
        } else {
            newWindow().open(url: url)
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

    // MARK: - Recent files

    var recentFiles: [URL] {
        (UserDefaults.standard.array(forKey: recentKey) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
    }

    func noteRecent(_ url: URL) {
        var paths = UserDefaults.standard.array(forKey: recentKey) as? [String] ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > maxRecent { paths = Array(paths.prefix(maxRecent)) }
        UserDefaults.standard.set(paths, forKey: recentKey)
        rebuildRecentMenu()
    }

    /// Builds a fresh "Open Recent" submenu (for the in-window File menu).
    func makeRecentMenu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        populateRecent(into: menu)
        return menu
    }

    private func populateRecent(into menu: NSMenu) {
        menu.removeAllItems()
        for url in recentFiles {
            let item = menu.addItem(withTitle: url.lastPathComponent,
                                    action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        if !recentFiles.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
    }

    private func rebuildRecentMenu() { populateRecent(into: openRecentMenu) }

    @objc private func openRecentItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { open(url: url) }
    }

    @objc private func clearRecent(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: recentKey)
        rebuildRecentMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Minimal macOS global menu — only what the OS needs (Quit/Hide). The
    /// visible Notepad menu lives inside the window, Windows-style.
    private func installGlobalMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Notepad", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Notepad", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Notepad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }
}
