import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
}

LaunchClock.start = Date()
AppFonts.registerBundledFonts()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
