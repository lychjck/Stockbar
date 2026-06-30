import AppKit
import ObjectiveC

/// Thin wrapper around the private `DFRFoundation.framework` and the private
/// `+[NSTouchBarItem addSystemTrayItem:]` class method.
///
/// These APIs let an app pin a custom `NSTouchBarItem` into the Control Strip
/// (the always-visible region on the right side of the Touch Bar, next to
/// Siri / brightness). They've been used in production by Pock / TouchBar
/// Stats / Mute Me for years; same surface is still present on macOS 26.4.
///
/// Every entry point is defensive: if the framework can't be loaded or the
/// symbol/selector isn't found, the call becomes a no-op. The Touch Bar app
/// will then just render nothing, instead of crashing on machines without a
/// DFR display or on a future macOS that retires these symbols.
enum DFRBridge {

    // MARK: - DFRFoundation framework

    private static let dfrFrameworkPath =
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"

    /// Lazy framework handle. `RTLD_LAZY` so we only resolve the few specific
    /// symbols we look up later — not the whole framework up front.
    private static let dfrHandle: UnsafeMutableRawPointer? = {
        dlopen(dfrFrameworkPath, RTLD_LAZY)
    }()

    /// True iff `DFRFoundation` was found and loaded. Callers should treat
    /// `false` as "Touch Bar features unavailable on this machine".
    static var isAvailable: Bool { dfrHandle != nil }

    // MARK: - DFRElementSetControlStripPresenceForIdentifier

    private typealias SetControlStripPresenceFn =
        @convention(c) (NSString, Bool) -> Void

    /// Make `identifier` appear in the Control Strip permanently. The matching
    /// `NSTouchBarItem` must have been registered via `addSystemTrayItem(_:)`
    /// first; this call only changes its *visibility*.
    static func setControlStripPresence(
        identifier: NSTouchBarItem.Identifier,
        present: Bool
    ) {
        guard
            let handle = dfrHandle,
            let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier")
        else { return }
        let fn = unsafeBitCast(sym, to: SetControlStripPresenceFn.self)
        fn(identifier.rawValue as NSString, present)
    }

    // MARK: - DFRSystemModalShowsCloseBoxWhenFrontMost

    private typealias ShowsCloseBoxFn = @convention(c) (Bool) -> Void

    /// Whether `presentSystemModalTouchBar(_:identifier:)` should show a close
    /// box on the right side. We pin this to `true` so the user can always tap
    /// out of any modal Touch Bar we present, back to the system strip.
    static func setSystemModalShowsCloseBoxWhenFrontMost(_ flag: Bool) {
        guard
            let handle = dfrHandle,
            let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost")
        else { return }
        let fn = unsafeBitCast(sym, to: ShowsCloseBoxFn.self)
        fn(flag)
    }

    // MARK: - +[NSTouchBarItem addSystemTrayItem:] / removeSystemTrayItem:
    //
    // Class methods on `NSTouchBarItem` exposed by AppKit but never made
    // public (around since macOS 10.12.2). We resolve them via the ObjC
    // runtime so we don't need a private bridging header.

    private typealias TrayItemIMP =
        @convention(c) (AnyObject, Selector, NSTouchBarItem) -> Void

    private static let addSelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeSelector = NSSelectorFromString("removeSystemTrayItem:")

    /// Register a custom Touch Bar item so it can live in the Control Strip
    /// (combined with `setControlStripPresence`).
    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        invokeTrayClassMethod(addSelector, item: item)
    }

    /// Reverse of `addSystemTrayItem`.
    static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        invokeTrayClassMethod(removeSelector, item: item)
    }

    private static func invokeTrayClassMethod(
        _ selector: Selector,
        item: NSTouchBarItem
    ) {
        guard
            let method = class_getClassMethod(NSTouchBarItem.self, selector)
        else { return }
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: TrayItemIMP.self)
        fn(NSTouchBarItem.self, selector, item)
    }

    // MARK: - +[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]
    //
    // Public ObjC API since macOS 10.12.2, but the Swift bridging declaration
    // was dropped in recent SDKs (Touch Bar hardware is EOL). The selector
    // still works at runtime, so we wire it through the ObjC runtime same as
    // the system-tray methods above.

    private typealias PresentSystemModalIMP =
        @convention(c) (AnyObject, Selector, NSTouchBar, NSTouchBarItem.Identifier) -> Void

    private static let presentSelector =
        NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")

    /// Replace the current Touch Bar with `touchBar`, anchored on the
    /// system-tray slot matching `identifier`. Tapping the close-box on the
    /// right of the strip dismisses it.
    static func presentSystemModalTouchBar(
        _ touchBar: NSTouchBar,
        systemTrayItemIdentifier identifier: NSTouchBarItem.Identifier
    ) {
        guard
            let method = class_getClassMethod(NSTouchBar.self, presentSelector)
        else { return }
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: PresentSystemModalIMP.self)
        fn(NSTouchBar.self, presentSelector, touchBar, identifier)
    }

    // MARK: - +[NSTouchBar dismissSystemModalTouchBar:]

    private typealias DismissSystemModalIMP =
        @convention(c) (AnyObject, Selector, NSTouchBar) -> Void

    private static let dismissSelector =
        NSSelectorFromString("dismissSystemModalTouchBar:")

    /// Programmatically dismiss a Touch Bar previously presented with
    /// `presentSystemModalTouchBar`.
    static func dismissSystemModalTouchBar(_ touchBar: NSTouchBar) {
        guard
            let method = class_getClassMethod(NSTouchBar.self, dismissSelector)
        else { return }
        let imp = method_getImplementation(method)
        let fn = unsafeBitCast(imp, to: DismissSystemModalIMP.self)
        fn(NSTouchBar.self, dismissSelector, touchBar)
    }
}
