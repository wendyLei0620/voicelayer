import Cocoa
import CoreGraphics

enum HotkeyPreset: String, CaseIterable {
    case ctrlSpace, optionSpace, rightOption

    var title: String {
        switch self {
        case .ctrlSpace: return "Control + 空格（按住说话）"
        case .optionSpace: return "Option + 空格（按住说话）"
        case .rightOption: return "右 Option（按住说话）"
        }
    }
}

/// 基于 CGEventTap 的全局按住说话热键。
///
/// - 用主动 tap，是为了能“吞掉”按键，避免 Ctrl+空格 同时触发系统的输入法切换。
/// - tap 运行在独立线程的 RunLoop 上。系统里每一次按键都要先经过这个回调，
///   如果它挂在主线程，主线程一旦被占用，整个系统的键盘输入都会跟着卡顿。
final class HotkeyManager {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private let lock = NSLock()
    private var _active = false
    private var _preset: HotkeyPreset = .ctrlSpace

    /// 回调线程与主线程都会读写，必须加锁。
    private var active: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
    var preset: HotkeyPreset {
        get { lock.lock(); defer { lock.unlock() }; return _preset }
        set { lock.lock(); _preset = newValue; lock.unlock() }
    }

    private var tap: CFMachPort?
    private var thread: Thread?

    private let kSpace: Int64 = 49
    private let kEsc: Int64 = 53
    private let kRightOption: Int64 = 61

    var isRunning: Bool { tap != nil }

    /// 返回 false 表示权限不足，创建 tap 失败。
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let done = DispatchSemaphore(value: 0)
        var created = false
        let t = Thread { [weak self] in
            created = self?.installTap() ?? false
            done.signal()
            if created { CFRunLoopRun() }
        }
        t.name = "VoiceLayer.hotkey"
        t.qualityOfService = .userInteractive
        t.start()
        done.wait()

        if created { thread = t }
        return created
    }

    /// 在当前线程（热键线程）上创建 tap 并挂到本线程的 RunLoop。
    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        return true
    }

    /// 外部（如处理流程结束）强制把状态复位。
    func reset() { active = false }

    private func fire(_ block: (() -> Void)?) {
        DispatchQueue.main.async { block?() }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.write("event tap 被系统禁用（\(type == .tapDisabledByTimeout ? "超时" : "用户输入")），已重新启用")
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let swallow = process(type: type, keyCode: keyCode, flags: event.flags)
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// 返回 true 表示吞掉该事件。回调里只做状态判断，不做任何耗时操作。
    private func process(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let p = preset

        // Esc 取消：只在录音中生效
        if type == .keyDown, keyCode == kEsc, active {
            active = false
            fire(onCancel)
            return true
        }

        switch p {
        case .ctrlSpace, .optionSpace:
            let mod: CGEventFlags = (p == .ctrlSpace) ? .maskControl : .maskAlternate
            let others: [CGEventFlags] = [.maskCommand, .maskShift, .maskControl, .maskAlternate].filter { $0 != mod }
            let hasOther = others.contains { flags.contains($0) }

            switch type {
            case .keyDown where keyCode == kSpace:
                if active { return true } // 按住时的自动重复
                if flags.contains(mod) && !hasOther {
                    active = true
                    fire(onStart)
                    return true
                }
                return false
            case .keyUp where keyCode == kSpace:
                if active {
                    active = false
                    fire(onStop)
                    return true
                }
                return false
            case .flagsChanged:
                // 先松开了修饰键，也视为结束
                if active && !flags.contains(mod) {
                    active = false
                    fire(onStop)
                }
                return false
            default:
                return false
            }

        case .rightOption:
            switch type {
            case .flagsChanged where keyCode == kRightOption:
                let pressed = flags.contains(.maskAlternate)
                if pressed && !active {
                    active = true
                    fire(onStart)
                } else if !pressed && active {
                    active = false
                    fire(onStop)
                }
                return false
            case .keyDown:
                // 按住右 Option 时又按了别的键，说明用户在打字，取消本次录音
                if active {
                    active = false
                    fire(onCancel)
                }
                return false
            default:
                return false
            }
        }
    }
}
