import Cocoa

/// 实时音量条
private final class LevelView: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.18).setFill()
        track.fill()

        let w = max(bounds.height, bounds.width * min(1, level))
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.systemGreen.setFill()
        fill.fill()
    }
}

/// 不抢焦点的悬浮提示条。
@MainActor
final class HUDPanel {
    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let levelView = LevelView()
    private var hideWork: DispatchWorkItem?
    private var smoothLevel: CGFloat = 0

    private let baseHeight: CGFloat = 44

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 关掉窗口阴影：阴影按矩形窗口描边，会在胶囊外面多出一圈细线
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 用蒙版把毛玻璃裁成胶囊形。图层圆角裁不掉窗口背后的模糊层，四角会露出矩形白底
        effect.maskImage = HUDPanel.capsuleMask(radius: 22)
        panel.contentView = effect

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        effect.addSubview(dot)

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        effect.addSubview(label)
        effect.addSubview(levelView)
    }

    // MARK: - 对外接口

    /// 可拉伸的圆角蒙版：四角固定，中间随窗口尺寸拉伸。
    private static func capsuleMask(radius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// 显示常驻状态（不自动消失）。
    func show(_ text: String, showLevel: Bool = false, color: NSColor = .systemRed) {
        hideWork?.cancel()
        layout(text: text, showLevel: showLevel, color: color)
        positionOnActiveScreen()
        panel.orderFrontRegardless()
    }

    func setText(_ text: String) {
        show(text, showLevel: false, color: .systemOrange)
    }

    func setLevel(_ l: Float) {
        // 简单平滑，避免条抖动
        smoothLevel = smoothLevel * 0.6 + CGFloat(l) * 0.4
        levelView.level = smoothLevel
    }

    /// 显示一条短暂提示，几秒后自动消失。
    func flash(_ text: String, error: Bool, seconds: Double = 3) {
        show(text, showLevel: false, color: error ? .systemRed : .systemYellow)
        scheduleHide(after: seconds)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    // MARK: - 内部

    private func scheduleHide(after s: Double) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work)
    }

    private func layout(text: String, showLevel: Bool, color: NSColor) {
        label.stringValue = text
        dot.layer?.backgroundColor = color.cgColor
        levelView.isHidden = !showLevel
        smoothLevel = 0
        levelView.level = 0

        // 最多两行，宽度上限 520
        let maxTextWidth: CGFloat = 520
        let font = label.font ?? .systemFont(ofSize: 14)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: 60),
            options: [.usesLineFragmentOrigin], attributes: [.font: font])
        let textW = min(ceil(rect.width) + 4, maxTextWidth)
        let textH = min(ceil(rect.height), 40)
        let height = max(baseHeight, textH + 20)

        let pad: CGFloat = 18
        let levelW: CGFloat = showLevel ? 70 : 0
        let gap: CGFloat = 10
        let total = pad + 10 + gap + textW + (showLevel ? gap + levelW : 0) + pad

        let w = max(150, total)
        dot.frame = NSRect(x: pad, y: (height - 10) / 2, width: 10, height: 10)
        label.frame = NSRect(x: pad + 10 + gap, y: (height - textH) / 2, width: textW, height: textH)
        levelView.frame = NSRect(x: w - pad - levelW, y: (height - 6) / 2, width: levelW, height: 6)

        var f = panel.frame
        f.size = NSSize(width: w, height: height)
        panel.setFrame(f, display: true)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 70)
        panel.setFrameOrigin(origin)
    }
}
