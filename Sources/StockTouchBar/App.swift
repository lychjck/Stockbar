import AppKit

/// Bootstrap. Mirrors the structure of StockBar's main entry so both targets
/// read alike. `@main` is required (instead of plain top-level code) because
/// `AppDelegate` is `@MainActor`-isolated — wrapping the construction inside
/// `static func main()` keeps the isolation check happy.
@main
@MainActor
final class StockTouchBarApp {
    static func main() {
        let app = NSApplication.shared
        // LSUIElement-style agent: no Dock icon, no main window, no menu bar
        // item. The only UI surface is the Control Strip Touch Bar widget
        // installed by AppDelegate / TouchBarController.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
