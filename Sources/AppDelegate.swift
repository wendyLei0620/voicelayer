import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private let settings = SettingsWindowController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Config.migrateUnstableAsrModel() {
            Log.write("已把识别模型从 qwen3-asr-1.7b 自动改为 qwen3-asr-0.6b（1.7b 在 OpenRouter 上会随机卡死）")
        }
        statusItem = NSStatusItem.systemStatusBar_variable()
        statusItem.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoiceLayer")
        menu.delegate = self
        statusItem.menu = menu

        settings.onSaved = { [weak self] in self?.refreshIcon() }
        controller.onStatusChange = { [weak self] in self?.refreshIcon() }
        controller.start()
        refreshIcon()

        // 首次启动没有 Key：直接打开设置
        if Config.apiKey.isEmpty { settings.present() }
    }

    // MARK: - 图标

    private func refreshIcon() {
        let status = controller.statusLine
        let name: String
        switch controller.state {
        case .recording: name = "mic.circle.fill"
        case .processing: name = "ellipsis.circle.fill"
        case .idle: name = status.ok ? "mic.fill" : "exclamationmark.triangle.fill"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "VoiceLayer")
    }

    // MARK: - 菜单（每次打开时重建，保证状态最新）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = controller.statusLine
        let statusItem = NSMenuItem(title: status.text, action: status.ok ? nil : #selector(openPermissionSettings), keyEquivalent: "")
        statusItem.target = self
        statusItem.isEnabled = !status.ok
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let hotkeyMenu = NSMenu()
        for p in HotkeyPreset.allCases {
            let item = NSMenuItem(title: p.title, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            item.state = (p == Config.hotkey) ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let polish = NSMenuItem(title: "整理成书面表达", action: #selector(togglePolish), keyEquivalent: "")
        polish.target = self
        polish.state = Config.polishEnabled ? .on : .off
        menu.addItem(polish)

        let copy = NSMenuItem(title: "复制上次结果", action: #selector(copyLast), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = !controller.lastResult.isEmpty
        menu.addItem(copy)

        menu.addItem(.separator())

        let permMenu = NSMenu()
        let ax = NSMenuItem(title: "辅助功能：\(Permissions.accessibilityGranted ? "已授权" : "未授权") · 打开设置",
                            action: #selector(openAX), keyEquivalent: "")
        ax.target = self
        let mic = NSMenuItem(title: "麦克风：\(Permissions.micGranted ? "已授权" : "未授权") · 打开设置",
                             action: #selector(openMic), keyEquivalent: "")
        mic.target = self
        let input = NSMenuItem(title: "输入监控 · 打开设置", action: #selector(openInput), keyEquivalent: "")
        input.target = self
        [ax, mic, input].forEach { permMenu.addItem($0) }
        if !Permissions.accessibilityGranted {
            permMenu.addItem(.separator())
            let fix = NSMenuItem(title: "修复辅助功能授权（开关已开但仍无效时点这里）",
                                 action: #selector(repairAX), keyEquivalent: "")
            fix.target = self
            permMenu.addItem(fix)
        }
        let permItem = NSMenuItem(title: "权限", action: nil, keyEquivalent: "")
        permItem.submenu = permMenu
        menu.addItem(permItem)

        let logItem = NSMenuItem(title: "打开诊断日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let set = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        set.target = self
        menu.addItem(set)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 VoiceLayer", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - 动作

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = HotkeyPreset(rawValue: raw) else { return }
        controller.setHotkey(p)
    }
    @objc private func togglePolish() { Config.polishEnabled.toggle() }
    @objc private func copyLast() { controller.copyLastResult() }
    @objc private func openSettings() { settings.present() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Log.dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: Log.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Log.url])
        } else {
            NSWorkspace.shared.open(Log.dir)
        }
    }

    @objc private func openPermissionSettings() {
        // 辅助功能判定为未授权时，直接走修复流程：重置本应用的旧条目并重新申请
        if !Permissions.accessibilityGranted { Permissions.repairAccessibility() }
        else if !controller.hotkeyRunning { Permissions.openSettings(.inputMonitoring) }
        else { Permissions.openSettings(.microphone) }
    }
    @objc private func repairAX() { Permissions.repairAccessibility() }
    @objc private func openAX() { Permissions.openSettings(.accessibility) }
    @objc private func openMic() { Permissions.openSettings(.microphone) }
    @objc private func openInput() { Permissions.openSettings(.inputMonitoring) }
}

private extension NSStatusItem {
    static func systemStatusBar_variable() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
