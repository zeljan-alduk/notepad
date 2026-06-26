import AppKit

/// A floating Find & Replace panel, one per editor window. Drives the focused
/// TextView's search/replace methods.
final class FindPanelController: NSWindowController {
    weak var textView: TextView?

    private let findField = NSTextField(frame: NSRect(x: 90, y: 148, width: 300, height: 22))
    private let replaceField = NSTextField(frame: NSRect(x: 90, y: 118, width: 300, height: 22))
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")

    /// Last term/flag, so Find Next (⌘G) works without the panel focused.
    var lastTerm: String { findField.stringValue }
    var caseSensitive: Bool { matchCase.state == .on }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 184),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Find and Replace"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildUI(in: panel.contentView!)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(in content: NSView) {
        func label(_ s: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.frame = NSRect(x: 10, y: y, width: 76, height: 20)
            l.alignment = .right
            return l
        }
        content.addSubview(label("Find what:", 150))
        content.addSubview(label("Replace with:", 120))
        findField.frame = NSRect(x: 92, y: 148, width: 300, height: 22)
        replaceField.frame = NSRect(x: 92, y: 118, width: 300, height: 22)
        content.addSubview(findField)
        content.addSubview(replaceField)

        matchCase.frame = NSRect(x: 92, y: 88, width: 200, height: 20)
        content.addSubview(matchCase)

        message.frame = NSRect(x: 12, y: 14, width: 380, height: 20)
        message.textColor = .secondaryLabelColor
        content.addSubview(message)

        func button(_ title: String, _ y: CGFloat, _ action: Selector, default def: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: 404, y: y, width: 108, height: 28)
            b.bezelStyle = .rounded
            if def { b.keyEquivalent = "\r" }
            return b
        }
        content.addSubview(button("Find Next", 148, #selector(findNextAction), default: true))
        content.addSubview(button("Find Previous", 118, #selector(findPrevAction)))
        content.addSubview(button("Replace", 84, #selector(replaceAction)))
        content.addSubview(button("Replace All", 50, #selector(replaceAllAction)))
    }

    /// Shows the panel for `tv`, pre-filling the term from the current selection.
    func present(for tv: TextView, focusReplace: Bool) {
        textView = tv
        let sel = tv.selectionText
        if !sel.isEmpty, sel.count < 200, !sel.contains("\n") {
            findField.stringValue = sel
        }
        message.stringValue = ""
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(focusReplace ? replaceField : findField)
    }

    // MARK: - Actions

    @objc private func findNextAction() { doFind(forward: true) }
    @objc private func findPrevAction() { doFind(forward: false) }

    private func doFind(forward: Bool) {
        guard let tv = textView, !findField.stringValue.isEmpty else { return }
        let ok = tv.findNext(findField.stringValue, caseSensitive: caseSensitive, forward: forward)
        report(ok)
    }

    @objc private func replaceAction() {
        guard let tv = textView, !findField.stringValue.isEmpty else { return }
        let ok = tv.replaceThenFind(findField.stringValue, with: replaceField.stringValue,
                                    caseSensitive: caseSensitive)
        report(ok)
    }

    @objc private func replaceAllAction() {
        guard let tv = textView, !findField.stringValue.isEmpty else { return }
        let count = tv.replaceAll(findField.stringValue, with: replaceField.stringValue,
                                  caseSensitive: caseSensitive)
        message.stringValue = "Replaced \(count) occurrence\(count == 1 ? "" : "s")."
    }

    private func report(_ found: Bool) {
        if found {
            message.stringValue = ""
        } else {
            message.stringValue = "Cannot find “\(findField.stringValue)”."
            NSSound.beep()
        }
    }
}
