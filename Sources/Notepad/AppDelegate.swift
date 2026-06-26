import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installGlobalMenu()

        let controller = EditorWindowController()
        self.controller = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // Open a file passed on the command line, if any.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            controller.open(url: URL(fileURLWithPath: path))
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { controller?.open(url: url) }
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
        NSApp.mainMenu = mainMenu
    }
}
