import Cocoa
import AVFoundation
import ApplicationServices

enum Permissions {
    static var micStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var micGranted: Bool { micStatus == .authorized }

    static func requestMic(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 是否允许向系统发送合成按键（自动粘贴依赖它），仅用于写诊断日志。
    static var postEventGranted: Bool { CGPreflightPostEventAccess() }

    /// 修复“系统设置里开关是开的，但应用仍判定没有权限”。
    /// 原因：临时签名的应用每次重新构建，代码签名都会变，系统里旧的授权条目对不上新程序。
    /// 做法：只重置本应用自己的辅助功能条目，再重新弹出授权，并打开对应设置页。
    static func repairAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.voicelayer.mvp"]
        p.standardOutput = nil
        p.standardError = nil
        var status: Int32 = -1
        do { try p.run(); p.waitUntilExit(); status = p.terminationStatus } catch {}
        Log.write("重置辅助功能授权 tccutil 退出码=\(status)")
        promptAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openSettings(.accessibility) }
    }

    /// 触发系统的辅助功能授权弹窗。
    static func promptAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
