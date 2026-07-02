import AppKit
import StockCore
import StockTouchBar

/// A simple preferences window for toggling menu bar and Touch Bar features.
/// Centered, fixed-size, with immediate-apply checkboxes.
@MainActor
final class PreferencesWindowController: NSWindowController {

    private let config: AppConfig
    private let onConfigChanged: (AppConfig) -> Void

    private var menuBarCheckbox: NSButton!
    private var touchBarCheckbox: NSButton!

    init(config: AppConfig, onConfigChanged: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onConfigChanged = onConfigChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "StockBar 设置"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentLayoutRect)
        contentView.wantsLayer = true

        // Title label
        let titleLabel = NSTextField(labelWithString: "界面显示")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 140, width: 360, height: 24)
        contentView.addSubview(titleLabel)

        // Menu bar checkbox
        menuBarCheckbox = NSButton(checkboxWithTitle: "显示菜单栏图标", target: self, action: #selector(menuBarToggled))
        menuBarCheckbox.state = config.enableMenuBar ? .on : .off
        menuBarCheckbox.frame = NSRect(x: 20, y: 100, width: 360, height: 24)
        contentView.addSubview(menuBarCheckbox)

        // Touch Bar checkbox
        touchBarCheckbox = NSButton(checkboxWithTitle: "显示 Touch Bar", target: self, action: #selector(touchBarToggled))
        touchBarCheckbox.state = config.enableTouchBar ? .on : .off
        touchBarCheckbox.frame = NSRect(x: 20, y: 70, width: 360, height: 24)

        // Check if Touch Bar is available
        if !DFRBridge.isAvailable {
            touchBarCheckbox.isEnabled = false
            touchBarCheckbox.toolTip = "此设备不支持 Touch Bar"
        }

        contentView.addSubview(touchBarCheckbox)

        // Info label
        let infoText = "更改立即生效，无需重启应用"
        let infoLabel = NSTextField(labelWithString: infoText)
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 30, width: 360, height: 20)
        contentView.addSubview(infoLabel)

        window.contentView = contentView
    }

    @objc private func menuBarToggled() {
        var updated = config
        updated.enableMenuBar = menuBarCheckbox.state == .on

        // Warn if both are disabled
        if !updated.enableMenuBar && !updated.enableTouchBar {
            let alert = NSAlert()
            alert.messageText = "至少需要启用一个界面"
            alert.informativeText = "如果菜单栏和 Touch Bar 都禁用，您将无法访问应用设置。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好的")
            alert.runModal()
            menuBarCheckbox.state = .on
            return
        }

        updated.save()
        onConfigChanged(updated)
    }

    @objc private func touchBarToggled() {
        var updated = config
        updated.enableTouchBar = touchBarCheckbox.state == .on

        // Warn if both are disabled
        if !updated.enableMenuBar && !updated.enableTouchBar {
            let alert = NSAlert()
            alert.messageText = "至少需要启用一个界面"
            alert.informativeText = "如果菜单栏和 Touch Bar 都禁用，您将无法访问应用设置。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好的")
            alert.runModal()
            touchBarCheckbox.state = .on
            return
        }

        updated.save()
        onConfigChanged(updated)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
