import AppKit
import CoreText

/// Bundled, OFL-licensed fonts that recreate the Windows look on any Mac:
/// Cascadia Mono (Consolas-like editor font) and Selawik (Segoe-UI-like chrome).
enum AppFonts {
    private static var registered = false

    /// Registers the bundled .ttf files for this process. Idempotent and cheap.
    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        let urls = (Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts")
                    ?? Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil)) ?? []
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// Monospaced editor font: Cascadia Mono, then any installed Consolas, then Menlo.
    static func editor(_ size: CGFloat) -> NSFont {
        NSFont(name: "CascadiaMono-Regular", size: size)
            ?? NSFont(name: "Consolas", size: size)
            ?? NSFont(name: "Menlo", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// UI/chrome font: Selawik, then any installed Segoe UI, then the system font.
    static func ui(_ size: CGFloat, semibold: Bool = false) -> NSFont {
        NSFont(name: semibold ? "Selawik-Semibold" : "Selawik-Regular", size: size)
            ?? NSFont(name: "Segoe UI", size: size)
            ?? .systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
    }
}
