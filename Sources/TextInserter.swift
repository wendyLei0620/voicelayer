import Cocoa
import ApplicationServices

struct FocusInfo {
    var role = ""
    var subrole = ""
    var secure = false
    var bundleID = ""
}

enum InsertFailure {
    case noAccessibility   // 没有辅助功能权限，发不出按键
    case eventFailed       // 按键事件创建失败
}

enum InsertResult {
    case inserted
    case skippedSecure
    case failed(InsertFailure)
}

struct InsertOutcome {
    var result: InsertResult
    var focus: FocusInfo
}

/// 把文字插入当前活跃输入框：剪贴板 + 模拟 Command+V，之后恢复用户原有剪贴板。
enum TextInserter {

    /// 读取当前焦点元素的信息。
    /// 辅助功能接口默认可能阻塞数秒（对方应用忙或不支持时），所以这里设了短超时，
    /// 并且调用方必须在后台线程里调用它，不能卡住主线程。
    static func inspectFocus() -> FocusInfo {
        var info = FocusInfo()
        info.bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard AXIsProcessTrusted() else { return info }

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return info }
        let element = f as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &v) == .success, let s = v as? String {
            info.role = s
        }
        v = nil
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &v) == .success, let s = v as? String {
            info.subrole = s
            info.secure = (s == "AXSecureTextField")
        }
        return info
    }

    @MainActor
    static func insert(_ text: String) async -> InsertOutcome {
        // 焦点检测放到后台线程，主线程不会被它拖住
        let focus = await Task.detached(priority: .userInitiated) { inspectFocus() }.value
        if focus.secure { return InsertOutcome(result: .skippedSecure, focus: focus) }

        let pb = NSPasteboard.general

        // 没有权限就发不出按键，直接把结果留在剪贴板
        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            return InsertOutcome(result: .failed(.noAccessibility), focus: focus)
        }

        let backup = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        // 遵循该约定的剪贴板管理器会忽略这次临时内容
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let ourCount = pb.changeCount

        // 如果用户还按着 Control/Option 等修饰键，模拟出来的 Command+V 会变成别的组合键
        await waitForModifiersReleased(timeout: 0.8)

        guard postPaste() else {
            return InsertOutcome(result: .failed(.eventFailed), focus: focus)
        }

        // 不在这里等待。剪贴板恢复放到后台，让悬浮条和流程立刻收尾。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            // 期间剪贴板被别的程序改动过，就不恢复，避免覆盖用户新复制的内容
            if pb.changeCount == ourCount { restore(backup, to: pb) }
        }
        return InsertOutcome(result: .inserted, focus: focus)
    }

    /// 把文字放进剪贴板（供“复制上次结果”和失败兜底使用）。
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - 内部

    private static func waitForModifiersReleased(timeout: Double) async {
        let mask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(mask).isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    private static func restore(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !snap.isEmpty else { return }
        let items: [NSPasteboardItem] = snap.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    /// 发送完整的按键序列：Command 按下 → V 按下 → V 抬起 → Command 抬起。
    /// 比只给 V 键加 flags 的做法兼容性更好，一些应用会检查修饰键自身的事件。
    private static func postPaste() -> Bool {
        // privateState：事件只携带我们设置的修饰键，不混入键盘当前的物理状态
        let src = CGEventSource(stateID: .privateState)
        let cmd: CGKeyCode = 55
        let v: CGKeyCode = 9

        func make(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            return e
        }
        guard let cmdDown = make(cmd, down: true, flags: .maskCommand),
              let vDown = make(v, down: true, flags: .maskCommand),
              let vUp = make(v, down: false, flags: .maskCommand),
              let cmdUp = make(cmd, down: false, flags: []) else { return false }

        for e in [cmdDown, vDown, vUp, cmdUp] {
            e.post(tap: .cghidEventTap)
            usleep(4_000)
        }
        return true
    }
}
