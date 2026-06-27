import AppKit

/// Custom About window: app icon, blurb, a Buy Me a Coffee button, and a link
/// to the GitHub project.
final class AboutWindowController: NSWindowController {
    static let coffeeURL = URL(string: "https://buymeacoffee.com/6txpkxt5kp")!
    static let githubURL = URL(string: "https://github.com/zeljan-alduk/flashpad")!

    init() {
        let w: CGFloat = 460, h: CGFloat = 380
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About FlashPad"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI(in: window.contentView!, w: w, h: h)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(in content: NSView, w: CGFloat, h: CGFloat) {
        // App icon.
        let icon = NSImageView(frame: NSRect(x: (w - 96) / 2, y: h - 124, width: 96, height: 96))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "FlashPad")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: h - 158, width: w, height: 28)
        content.addSubview(title)

        let version = NSTextField(labelWithString: "Version 1.0")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        version.frame = NSRect(x: 0, y: h - 178, width: w, height: 18)
        content.addSubview(version)

        let blurb = NSTextField(wrappingLabelWithString:
            "A fast, native macOS clone of Windows 10 FlashPad — built to open and scroll multi-gigabyte files instantly with a small footprint.")
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .secondaryLabelColor
        blurb.alignment = .center
        blurb.frame = NSRect(x: 40, y: h - 236, width: w - 80, height: 50)
        content.addSubview(blurb)

        // Buy Me a Coffee — brand-yellow pill.
        let coffee = CoffeePillButton(title: "☕  Buy me a coffee",
                                      target: self, action: #selector(openCoffee))
        coffee.frame = NSRect(x: (w - 230) / 2, y: 72, width: 230, height: 44)
        content.addSubview(coffee)

        // GitHub link.
        let github = NSButton(title: "View the project on GitHub", target: self, action: #selector(openGitHub))
        github.bezelStyle = .inline
        github.isBordered = false
        github.contentTintColor = .linkColor
        github.font = .systemFont(ofSize: 12)
        github.frame = NSRect(x: 0, y: 36, width: w, height: 20)
        github.alignment = .center
        content.addSubview(github)

        let credit = NSTextField(labelWithString: "© 2026 Željan Alduk")
        credit.font = .systemFont(ofSize: 10)
        credit.textColor = .tertiaryLabelColor
        credit.alignment = .center
        credit.frame = NSRect(x: 0, y: 12, width: w, height: 14)
        content.addSubview(credit)
    }

    @objc private func openCoffee() { NSWorkspace.shared.open(Self.coffeeURL) }
    @objc private func openGitHub() { NSWorkspace.shared.open(Self.githubURL) }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A rounded, Buy-Me-a-Coffee brand-yellow button.
private final class CoffeePillButton: NSButton {
    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        styleTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func commonInit() {
        isBordered = false
        wantsLayer = true
        bezelStyle = .regularSquare
        layer?.backgroundColor = NSColor(red: 1.0, green: 0.867, blue: 0.0, alpha: 1).cgColor  // #FFDD00
        layer?.cornerRadius = 22
    }
    private func styleTitle() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor(white: 0.1, alpha: 1),
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ])
    }
    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
    }
}
