import Cocoa
import AVFoundation

/// 主流程：快捷键 → 录音 → 识别 → 整理 → 插入。
@MainActor
final class AppController {
    enum State { case idle, recording, processing }

    private let hotkey = HotkeyManager()
    private let recorder = AudioRecorder()
    let hud = HUDPanel()

    private(set) var state: State = .idle
    private(set) var lastResult = ""

    private var recordStartedAt = Date()
    private var maxTimer: Timer?
    private var retryTimer: Timer?
    private var askedAccessibility = false

    /// 菜单栏据此刷新状态行
    var onStatusChange: (() -> Void)?

    private let minDuration = 0.4

    var hotkeyRunning: Bool { hotkey.isRunning }

    // MARK: - 启动

    func start() {
        hotkey.preset = Config.hotkey

        hotkey.onStart = { [weak self] in MainActor.assumeIsolated { self?.handleStart() } }
        hotkey.onStop = { [weak self] in MainActor.assumeIsolated { self?.handleStop() } }
        hotkey.onCancel = { [weak self] in MainActor.assumeIsolated { self?.handleCancel() } }

        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hud.setLevel(level) } }
        }

        if Permissions.micStatus == .notDetermined {
            Permissions.requestMic { [weak self] _ in self?.onStatusChange?() }
        }
        ensureHotkey()

        Log.write("启动 ax=\(Permissions.accessibilityGranted) postEvent=\(Permissions.postEventGranted) " +
                  "mic=\(Permissions.micStatus.rawValue) tap=\(hotkey.isRunning) " +
                  "provider=\(Config.host(of: Config.baseURL)) asr=\(Config.asrModel) llm=\(Config.llmModel) " +
                  "内存=\(String(format: "%.0f", Log.footprintMB()))MB")
    }

    /// 创建热键 tap；权限不足时每 2 秒重试，授权后自动生效。
    private func ensureHotkey() {
        // 辅助功能权限同时决定能不能自动粘贴，没授权就主动弹一次系统授权提示
        if !Permissions.accessibilityGranted && !askedAccessibility {
            askedAccessibility = true
            Permissions.promptAccessibility()
        }
        if hotkey.start() && Permissions.accessibilityGranted {
            retryTimer?.invalidate(); retryTimer = nil
            onStatusChange?()
            return
        }
        onStatusChange?()
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensureHotkey() }
            }
        }
    }

    func setHotkey(_ preset: HotkeyPreset) {
        Config.hotkey = preset
        hotkey.preset = preset
        hotkey.reset()
        onStatusChange?()
    }

    // MARK: - 事件处理

    private func handleStart() {
        guard state == .idle else {
            hotkey.reset()
            if state == .processing { hud.flash("上一条还在处理，请稍候", error: false, seconds: 1.5) }
            return
        }
        guard !Config.apiKey.isEmpty else {
            hotkey.reset()
            hud.flash("请先在菜单栏「设置」里填写 API Key", error: true)
            return
        }
        switch Permissions.micStatus {
        case .authorized: break
        case .notDetermined:
            hotkey.reset()
            Permissions.requestMic { _ in }
            hud.flash("请在弹窗中允许使用麦克风，然后再试一次", error: true)
            return
        default:
            hotkey.reset()
            hud.flash("没有麦克风权限，请在系统设置中开启", error: true)
            return
        }

        do {
            try recorder.start()
        } catch {
            hotkey.reset()
            hud.flash("无法开始录音：\(error.localizedDescription)", error: true)
            return
        }

        state = .recording
        recordStartedAt = Date()
        hud.show("聆听中", showLevel: true, color: .systemRed)

        maxTimer?.invalidate()
        maxTimer = Timer.scheduledTimer(withTimeInterval: AudioRecorder.maxSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hotkey.reset()
                self?.handleStop()
            }
        }
        onStatusChange?()
    }

    private func handleStop() {
        guard state == .recording else { return }
        maxTimer?.invalidate(); maxTimer = nil
        let released = Date()
        let (wav, duration) = recorder.stop()

        if duration < minDuration {
            state = .idle
            hud.hide()
            onStatusChange?()
            return
        }

        state = .processing
        hud.show("识别中…", showLevel: false, color: .systemOrange)
        onStatusChange?()
        Task { await self.process(wav: wav, audioSeconds: duration, releasedAt: released) }
    }

    private func handleCancel() {
        guard state == .recording else { return }
        maxTimer?.invalidate(); maxTimer = nil
        _ = recorder.stop()
        state = .idle
        hud.flash("已取消", error: false, seconds: 0.8)
        onStatusChange?()
    }

    // MARK: - 处理流程

    private func process(wav: Data, audioSeconds: Double, releasedAt: Date) async {
        defer {
            state = .idle
            hotkey.reset()
            onStatusChange?()
        }

        func secs(_ a: Date, _ b: Date = Date()) -> String { String(format: "%.2f", b.timeIntervalSince(a)) }

        do {
            let tAsr0 = Date()
            let raw = try await CloudClient.transcribe(wav: wav)
            let asr = secs(tAsr0)
            guard !raw.isEmpty else {
                Log.write("听写 audio=\(String(format: "%.1f", audioSeconds))s asr=\(asr)s 结果为空")
                hud.flash("没有听清，请再说一次", error: true)
                return
            }

            var text = raw
            var note: String?
            var polishInfo = "关闭"
            if Config.polishEnabled {
                if CloudClient.needsPolish(raw) {
                    hud.setText("整理中…")
                    let t0 = Date()
                    do {
                        text = try await CloudClient.polish(raw)
                        polishInfo = "\(secs(t0))s"
                    } catch {
                        text = raw
                        note = "整理失败，已使用识别原文"
                        polishInfo = "失败(\(secs(t0))s):\(error.localizedDescription)"
                    }
                } else {
                    polishInfo = "跳过(短句)"
                }
            }
            lastResult = text

            let tIns0 = Date()
            let outcome = await TextInserter.insert(text)
            let insert = secs(tIns0)

            var resultTag = "ok"
            switch outcome.result {
            case .inserted:
                if let note { hud.flash(note, error: false) } else { hud.hide() }
            case .skippedSecure:
                resultTag = "跳过密码框"
                hud.flash("已跳过密码输入框", error: true)
            case .failed(.noAccessibility):
                resultTag = "失败:无辅助功能权限"
                hud.flash("辅助功能权限没有生效，无法自动粘贴。结果已复制，请按 ⌘V。修复：系统设置里删除 VoiceLayer 后重新添加",
                          error: true, seconds: 6)
            case .failed(.eventFailed):
                resultTag = "失败:按键事件创建失败"
                hud.flash("无法发送粘贴按键，结果已复制，请按 ⌘V", error: true, seconds: 4)
            }

            Log.write("听写 audio=\(String(format: "%.1f", audioSeconds))s asr=\(asr)s polish=\(polishInfo) " +
                      "insert=\(insert)s 松手到上屏=\(secs(releasedAt))s 字数=\(raw.count)→\(text.count) " +
                      "结果=\(resultTag) 前台=\(outcome.focus.bundleID) 焦点=\(outcome.focus.role)/\(outcome.focus.subrole) " +
                      "ax=\(Permissions.accessibilityGranted) 内存=\(String(format: "%.0f", Log.footprintMB()))MB")
        } catch {
            Log.write("听写失败 audio=\(String(format: "%.1f", audioSeconds))s \(error.localizedDescription) " +
                      "松手后=\(secs(releasedAt))s")
            hud.flash(error.localizedDescription, error: true, seconds: 4)
        }
    }

    // MARK: - 菜单用

    func copyLastResult() {
        guard !lastResult.isEmpty else { return }
        TextInserter.copyToClipboard(lastResult)
    }

    /// 菜单栏第一行的状态文案。
    var statusLine: (text: String, ok: Bool) {
        if !hotkey.isRunning { return ("⚠ 需要辅助功能权限（点击打开系统设置）", false) }
        // 按键监听能工作，不代表有权限发送粘贴按键。两者要分开检查。
        if !Permissions.accessibilityGranted {
            return ("⚠ 辅助功能权限未生效，无法自动粘贴（点击打开系统设置）", false)
        }
        if Permissions.micStatus == .denied || Permissions.micStatus == .restricted {
            return ("⚠ 需要麦克风权限（点击打开系统设置）", false)
        }
        if Config.apiKey.isEmpty { return ("⚠ 请先设置 API Key", false) }
        switch state {
        case .idle: return ("就绪 · 按住 \(shortName(Config.hotkey)) 说话", true)
        case .recording: return ("正在聆听…", true)
        case .processing: return ("处理中…", true)
        }
    }

    private func shortName(_ p: HotkeyPreset) -> String {
        switch p {
        case .ctrlSpace: return "Control + 空格"
        case .optionSpace: return "Option + 空格"
        case .rightOption: return "右 Option"
        }
    }
}
