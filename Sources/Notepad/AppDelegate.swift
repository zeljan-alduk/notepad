import AppKit

enum LaunchClock { static var start = Date() }

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One controller per open window. Each owns its own document, so windows
    /// share only the AppKit frameworks — a new window costs a few MB + its file.
    private var controllers: [EditorWindowController] = []

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
        fileMenu.addItem(.separator())
        // nil target → routed to the key window's EditorWindowController.
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
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

        NSApp.mainMenu = mainMenu
    }
}
