import Foundation

/// 预置的云端服务商。三项都是 OpenAI 兼容接口，只是地址与模型名不同。
enum ProviderPreset: String, CaseIterable {
    case siliconflow, openrouter, custom

    var title: String {
        switch self {
        case .siliconflow: return "硅基流动 SiliconFlow"
        case .openrouter: return "OpenRouter"
        case .custom: return "自定义"
        }
    }
    var baseURL: String {
        switch self {
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }
    /// 识别模型
    var asrModel: String {
        switch self {
        case .siliconflow: return "FunAudioLLM/SenseVoiceSmall"
        // 用 0.6b 而不是 1.7b：实测 1.7b 在 OpenRouter 上约三分之一请求会随机卡死，0.6b 24/24 稳定
        case .openrouter: return "qwen/qwen3-asr-0.6b"
        case .custom: return ""
        }
    }
    /// 整理模型。选的都是非推理模型，避免“思考”拖慢延迟。
    var llmModel: String {
        switch self {
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .openrouter: return "qwen/qwen3-30b-a3b-instruct-2507"
        case .custom: return ""
        }
    }

    static func detect(baseURL: String) -> ProviderPreset {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? ""
        if host.contains("siliconflow") { return .siliconflow }
        if host.contains("openrouter.ai") { return .openrouter }
        return .custom
    }
}

/// 用户可配置项，存放在 UserDefaults。
/// MVP 阶段 API Key 也放在这里；后续应迁移到 Keychain。
enum Config {
    private static let d = UserDefaults.standard

    /// API Key 按接口主机分别保存，切换服务商时不会把一家的 Key 发给另一家。
    static func host(of base: String) -> String {
        URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "default"
    }
    static func apiKey(forBase base: String) -> String {
        d.string(forKey: "apiKey@\(host(of: base))") ?? ""
    }
    static func setApiKey(_ key: String, forBase base: String) {
        d.set(key, forKey: "apiKey@\(host(of: base))")
    }

    static var apiKey: String {
        let k = apiKey(forBase: baseURL)
        if !k.isEmpty { return k }
        return ProcessInfo.processInfo.environment["VOICELAYER_API_KEY"] ?? ""
    }

    static var baseURL: String {
        get { d.string(forKey: "baseURL") ?? ProviderPreset.siliconflow.baseURL }
        set { d.set(newValue, forKey: "baseURL") }
    }
    static var asrModel: String {
        // 环境变量 VOICELAYER_ASR_MODEL 仅用于命令行调试，优先于已保存的设置，不会写入设置
        get { ProcessInfo.processInfo.environment["VOICELAYER_ASR_MODEL"]
                ?? d.string(forKey: "asrModel") ?? ProviderPreset.siliconflow.asrModel }
        set { d.set(newValue, forKey: "asrModel") }
    }
    static var llmModel: String {
        get { d.string(forKey: "llmModel") ?? ProviderPreset.siliconflow.llmModel }
        set { d.set(newValue, forKey: "llmModel") }
    }
    /// 是否做 LLM 文本整理；关闭则只插入识别原文。
    static var polishEnabled: Bool {
        get { d.object(forKey: "polishEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "polishEnabled") }
    }
    static var hotkey: HotkeyPreset {
        get { HotkeyPreset(rawValue: d.string(forKey: "hotkey") ?? "") ?? .ctrlSpace }
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var trimmedBase: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 一次性迁移：OpenRouter 上的 qwen3-asr-1.7b 实测会随机卡死（约三分之一请求），换成稳定的 0.6b。
    /// 只迁移一次；之后用户自己改回 1.7b 不会再被覆盖。
    @discardableResult
    static func migrateUnstableAsrModel() -> Bool {
        guard !d.bool(forKey: "migrated.asr06") else { return false }
        d.set(true, forKey: "migrated.asr06")
        guard ProviderPreset.detect(baseURL: baseURL) == .openrouter,
              d.string(forKey: "asrModel") == "qwen/qwen3-asr-1.7b" else { return false }
        d.set("qwen/qwen3-asr-0.6b", forKey: "asrModel")
        return true
    }

    /// 旧版本把 Key 存在统一的 "apiKey" 下。迁移到当前接口主机名下，并删除旧值。
    static func migrateLegacyKey() {
        guard let legacy = d.string(forKey: "apiKey"), !legacy.isEmpty else { return }
        if apiKey(forBase: baseURL).isEmpty { setApiKey(legacy, forBase: baseURL) }
        d.removeObject(forKey: "apiKey")
    }
}
