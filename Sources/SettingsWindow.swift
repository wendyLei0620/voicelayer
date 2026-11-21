import Cocoa

/// 设置窗口：服务商、API Key、接口地址、两个模型。保存即时生效。
@MainActor
final class SettingsWindowController: NSWindowController {
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSSecureTextField()
    private let baseField = NSTextField()
    private let asrField = NSTextField()
    private let llmField = NSTextField()
    private let hint = NSTextField(wrappingLabelWithString: "")
    var onSaved: (() -> Void)?

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "VoiceLayer 设置"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        build(in: win.contentView!)
        win.center()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build(in view: NSView) {
        var y: CGFloat = 262

        func addLabel(_ title: String, at y: CGFloat) {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.frame = NSRect(x: 20, y: y, width: 80, height: 22)
            view.addSubview(label)
        }

        // 服务商
        addLabel("服务商", at: y)
        ProviderPreset.allCases.forEach { providerPopup.addItem(withTitle: $0.title) }
        providerPopup.frame = NSRect(x: 108, y: y - 3, width: 260, height: 26)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        view.addSubview(providerPopup)
        y -= 42

        let rows: [(String, NSTextField, String)] = [
            ("API Key", keyField, "该服务商的 Key"),
            ("接口地址", baseField, "https://…/v1"),
            ("识别模型", asrField, "语音识别模型名"),
            ("整理模型", llmField, "对话模型名（建议非推理模型）"),
        ]
        for (title, field, placeholder) in rows {
            addLabel(title, at: y)
            field.placeholderString = placeholder
            field.frame = NSRect(x: 110, y: y - 2, width: 390, height: 24)
            view.addSubview(field)
            y -= 40
        }

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 110, y: 48, width: 390, height: 44)
        view.addSubview(hint)

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 420, y: 12, width: 80, height: 30)
        view.addSubview(save)
    }

    func present() {
        let preset = ProviderPreset.detect(baseURL: Config.baseURL)
        providerPopup.selectItem(at: ProviderPreset.allCases.firstIndex(of: preset) ?? 0)
        baseField.stringValue = Config.baseURL
        asrField.stringValue = Config.asrModel
        llmField.stringValue = Config.llmModel
        keyField.stringValue = Config.apiKey(forBase: Config.baseURL)
        updateHint(preset)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private var selectedPreset: ProviderPreset {
        ProviderPreset.allCases[max(0, providerPopup.indexOfSelectedItem)]
    }

    /// 切换服务商：自动填入该服务商的地址与默认模型，并载入该服务商对应的 Key。
    @objc private func providerChanged() {
        let p = selectedPreset
        if p != .custom {
            baseField.stringValue = p.baseURL
            asrField.stringValue = p.asrModel
            llmField.stringValue = p.llmModel
        }
        keyField.stringValue = Config.apiKey(forBase: baseField.stringValue)
        updateHint(p)
    }

    private func updateHint(_ p: ProviderPreset) {
        switch p {
        case .siliconflow:
            hint.stringValue = "硅基流动：识别用 SenseVoice，整理用 Qwen2.5-7B。国内直连。"
        case .openrouter:
            hint.stringValue = "OpenRouter：识别用 Qwen3-ASR（支持中文及方言），整理用 Qwen3-30B-A3B-Instruct（非推理，速度快）。模型名必须是 OpenRouter 上的名称。"
        case .custom:
            hint.stringValue = "自定义：需要兼容 /audio/transcriptions 与 /chat/completions，模型名按该服务商的命名填写。"
        }
    }

    @objc private func save() {
        let base = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let asr = asrField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let llm = llmField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if !base.isEmpty {
            Config.baseURL = base
            Config.setApiKey(key, forBase: base)
        }
        if !asr.isEmpty { Config.asrModel = asr }
        if !llm.isEmpty { Config.llmModel = llm }
        window?.close()
        onSaved?()
    }
}
