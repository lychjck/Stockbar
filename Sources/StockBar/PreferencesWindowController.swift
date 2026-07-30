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
    private var tzzbApiTextField: NSTextField!
    private var tzzbStatusLabel: NSTextField!
    private var tzzbTestButton: NSButton!

    init(config: AppConfig, onConfigChanged: @escaping (AppConfig) -> Void) {
        self.config = config
        self.onConfigChanged = onConfigChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
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

        var yPos: CGFloat = 270

        // ---- Section 1: Interface Display ----
        let titleLabel = NSTextField(labelWithString: "界面显示")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 440, height: 24)
        contentView.addSubview(titleLabel)
        yPos -= 30

        // Menu bar checkbox
        menuBarCheckbox = NSButton(checkboxWithTitle: "显示菜单栏图标", target: self, action: #selector(menuBarToggled))
        menuBarCheckbox.state = config.enableMenuBar ? .on : .off
        menuBarCheckbox.frame = NSRect(x: 20, y: yPos, width: 440, height: 24)
        contentView.addSubview(menuBarCheckbox)
        yPos -= 30

        // Touch Bar checkbox
        touchBarCheckbox = NSButton(checkboxWithTitle: "显示 Touch Bar", target: self, action: #selector(touchBarToggled))
        touchBarCheckbox.state = config.enableTouchBar ? .on : .off
        touchBarCheckbox.frame = NSRect(x: 20, y: yPos, width: 440, height: 24)

        // Check if Touch Bar is available
        if !DFRBridge.isAvailable {
            touchBarCheckbox.isEnabled = false
            touchBarCheckbox.toolTip = "此设备不支持 Touch Bar"
        }

        contentView.addSubview(touchBarCheckbox)
        yPos -= 40

        // ---- Section 2: tzzb Integration ----
        let tzzbTitleLabel = NSTextField(labelWithString: "投资账本集成")
        tzzbTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        tzzbTitleLabel.frame = NSRect(x: 20, y: yPos, width: 440, height: 24)
        contentView.addSubview(tzzbTitleLabel)
        yPos -= 30

        // API URL label
        let apiLabel = NSTextField(labelWithString: "tzzb API 地址:")
        apiLabel.font = .systemFont(ofSize: 13)
        apiLabel.frame = NSRect(x: 20, y: yPos, width: 120, height: 20)
        apiLabel.alignment = .right
        contentView.addSubview(apiLabel)

        // API URL text field
        tzzbApiTextField = NSTextField(frame: NSRect(x: 150, y: yPos - 2, width: 240, height: 24))
        tzzbApiTextField.placeholderString = "http://127.0.0.1:8080"
        tzzbApiTextField.stringValue = config.tzzbApiUrl ?? ""
        tzzbApiTextField.target = self
        tzzbApiTextField.action = #selector(tzzbApiChanged)
        contentView.addSubview(tzzbApiTextField)

        // Test button
        tzzbTestButton = NSButton(title: "测试", target: self, action: #selector(testTzzbConnection))
        tzzbTestButton.frame = NSRect(x: 400, y: yPos - 2, width: 60, height: 24)
        tzzbTestButton.bezelStyle = .rounded
        contentView.addSubview(tzzbTestButton)
        yPos -= 30

        // Status label
        tzzbStatusLabel = NSTextField(labelWithString: "")
        tzzbStatusLabel.font = .systemFont(ofSize: 11)
        tzzbStatusLabel.textColor = .secondaryLabelColor
        tzzbStatusLabel.frame = NSRect(x: 150, y: yPos, width: 310, height: 20)
        tzzbStatusLabel.isEditable = false
        tzzbStatusLabel.isBezeled = false
        tzzbStatusLabel.drawsBackground = false
        contentView.addSubview(tzzbStatusLabel)
        yPos -= 25

        // Info text
        let tzzbInfoLabel = NSTextField(wrappingLabelWithString: "启用后，StockBar 将从 tzzb 自动同步持仓并显示成本和盈亏。留空则使用本地 watchlist.json。")
        tzzbInfoLabel.font = .systemFont(ofSize: 11)
        tzzbInfoLabel.textColor = .secondaryLabelColor
        tzzbInfoLabel.frame = NSRect(x: 150, y: yPos - 20, width: 310, height: 40)
        contentView.addSubview(tzzbInfoLabel)
        yPos -= 50

        // ---- Bottom info ----
        let infoText = "更改立即生效，无需重启应用"
        let infoLabel = NSTextField(labelWithString: infoText)
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 20, width: 440, height: 20)
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

    @objc private func tzzbApiChanged() {
        var updated = config
        let newValue = tzzbApiTextField.stringValue.trimmingCharacters(in: .whitespaces)
        updated.tzzbApiUrl = newValue.isEmpty ? nil : newValue
        updated.save()
        onConfigChanged(updated)
        tzzbStatusLabel.stringValue = ""
    }

    @objc private func testTzzbConnection() {
        let urlString = tzzbApiTextField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else {
            tzzbStatusLabel.stringValue = "请先输入 API 地址"
            tzzbStatusLabel.textColor = .systemRed
            return
        }

        tzzbTestButton.isEnabled = false
        tzzbStatusLabel.stringValue = "测试中..."
        tzzbStatusLabel.textColor = .secondaryLabelColor

        Task {
            let client = TzzbClient(baseURL: urlString)
            if let positions = await client.fetchPositions() {
                await MainActor.run {
                    tzzbStatusLabel.stringValue = "✓ 连接成功，找到 \(positions.count) 个持仓"
                    tzzbStatusLabel.textColor = .systemGreen
                    tzzbTestButton.isEnabled = true

                    // Save the config when test succeeds
                    var updated = config
                    updated.tzzbApiUrl = urlString
                    updated.save()
                    onConfigChanged(updated)
                }
            } else {
                await MainActor.run {
                    tzzbStatusLabel.stringValue = "✗ 连接失败，请检查 tzzb 是否运行"
                    tzzbStatusLabel.textColor = .systemRed
                    tzzbTestButton.isEnabled = true
                }
            }
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
