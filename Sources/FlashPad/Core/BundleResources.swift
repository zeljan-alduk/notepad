import Foundation

extension Bundle {
    /// Resources live in the SwiftPM resource bundle (`Bundle.module`) for
    /// `swift build`/`swift run`, and directly in the app bundle (`Bundle.main`)
    /// for the Xcode/App Store build. This resolves to whichever applies.
    static var appResources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}
