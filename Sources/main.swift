import Cocoa

// 入口：默认启动菜单栏应用；带调试参数时只跑对应的自测，不启动界面。
//
//   VoiceLayer --selftest <16kHz wav>   识别 + 整理，打印结果
//   VoiceLayer --polish "<文本>"          只测试整理
//   VoiceLayer --bench <wav> [次数]       反复调用识别和整理，统计耗时分布与内存变化
//   VoiceLayer --hud-demo               循环展示悬浮条各状态

let args = CommandLine.arguments

// 旧版本把 Key 存在统一的位置，这里迁移到按服务商分开保存的新位置
Config.migrateLegacyKey()

func argValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let path = argValue("--selftest") {
    Task {
        do {
            let wav = try Data(contentsOf: URL(fileURLWithPath: path))
            let t0 = Date()
            let raw = try await CloudClient.transcribe(wav: wav)
            let t1 = Date()
            print("识别原文：\(raw)")
            print(String(format: "识别耗时：%.2f 秒", t1.timeIntervalSince(t0)))
            do {
                let out = try await CloudClient.polish(raw)
                print("整理结果：\(out)")
                print(String(format: "整理耗时：%.2f 秒", Date().timeIntervalSince(t1)))
            } catch {
                print("整理失败（实际使用时会回退原文）：\(error.localizedDescription)")
            }
            exit(0)
        } catch {
            print("失败：\(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if let path = argValue("--bench") {
    let n = max(2, Int(args.last.flatMap { Int($0) } ?? 8))
    Task {
        func stats(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "-" }
            let s = v.sorted()
            return String(format: "最小 %.2f / 中位 %.2f / 最大 %.2f 秒", s.first!, s[s.count / 2], s.last!)
        }
        do {
            let wav = try Data(contentsOf: URL(fileURLWithPath: path))
            print(String(format: "音频 %.1f KB，共 %d 轮，起始内存 %.0f MB", Double(wav.count) / 1024, n, Log.footprintMB()))
            var asr: [Double] = [], pol: [Double] = []
            var raw = ""
            var rss: [Double] = []
            for i in 1...n {
                var t = Date()
                raw = try await CloudClient.transcribe(wav: wav)
                let a = Date().timeIntervalSince(t)
                asr.append(a)
                t = Date()
                var p = -1.0
                if let _ = try? await CloudClient.polish(raw + "，呃，就是明天开会那个事情") { p = Date().timeIntervalSince(t); pol.append(p) }
                rss.append(Log.footprintMB())
                print(String(format: "第 %d 轮：识别 %.2f 秒，整理 %.2f 秒，内存 %.0f MB", i, a, p, rss.last!))
            }
            print("首轮识别（含冷连接）：" + String(format: "%.2f 秒", asr[0]))
            print("后续识别（复用连接）：" + stats(Array(asr.dropFirst())))
            print("整理：" + stats(pol))
            print(String(format: "内存：首轮后 %.0f MB，末轮后 %.0f MB，增长 %.1f MB", rss[0], rss.last!, rss.last! - rss[0]))
            exit(0)
        } catch {
            print("失败：\(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if let path = argValue("--bench-asr") {
    // 用法：--bench-asr <wav> <模型id> <次数>   对比 multipart / JSON / 每次新连接 三种请求方式
    let model = args.count > 3 ? args[3] : Config.asrModel
    let n = args.count > 4 ? (Int(args[4]) ?? 6) : 6
    Task {
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: path)) else { print("读不到音频"); exit(1) }
        print("模型 \(model)，每种方式 \(n) 次，单次超时 20 秒，不重试")
        let variants: [(String, Bool, Bool)] = [
            ("multipart 复用连接", false, false),
            ("JSON base64 复用连接", true, false),
            ("multipart 每次新连接", false, true),
            ("JSON base64 每次新连接", true, true),
        ]
        for (name, json, fresh) in variants {
            var ts: [Double] = []
            var fails = 0
            for _ in 1...n {
                let r = await CloudClient.experimentASR(wav: wav, model: model, json: json, freshConnection: fresh, timeout: 20)
                ts.append(r.seconds)
                if r.result.hasPrefix("失败") { fails += 1 }
            }
            let s = ts.map { String(format: "%.1f", $0) }.joined(separator: " ")
            print("\(name)：\(s)   （失败 \(fails)/\(n)）")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if let text = argValue("--polish") {
    Task {
        do {
            let t0 = Date()
            let out = try await CloudClient.polish(text)
            print("输入：\(text)")
            print("输出：\(out)")
            print(String(format: "耗时：%.2f 秒", Date().timeIntervalSince(t0)))
            exit(0)
        } catch {
            print("失败：\(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if args.contains("--hud-demo") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let hud = HUDPanel()
        let steps: [(String, () -> Void)] = [
            ("聆听中", { hud.show("聆听中", showLevel: true, color: .systemRed) }),
            ("识别中", { hud.show("识别中…", showLevel: false, color: .systemOrange) }),
            ("整理中", { hud.setText("整理中…") }),
            ("提示", { hud.flash("整理失败，已使用识别原文", error: false, seconds: 1.5) }),
            ("错误", { hud.flash("API Key 无效（401）", error: true, seconds: 1.5) }),
        ]
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { t in
            MainActor.assumeIsolated {
                if i >= steps.count { hud.hide(); print("演示结束"); exit(0) }
                print("展示：\(steps[i].0)")
                steps[i].1()
                // 聆听中时模拟音量
                if i == 0 {
                    var n = 0.0
                    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { tt in
                        n += 0.3
                        MainActor.assumeIsolated { hud.setLevel(Float(abs(sin(n)))) }
                        if n > 4.5 { tt.invalidate() }
                    }
                }
                i += 1
            }
        }
    }
    app.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
