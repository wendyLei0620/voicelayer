import Foundation

/// 诊断日志，写到 ~/Library/Logs/VoiceLayer/voicelayer.log。
/// 只记录耗时、长度、权限状态，不记录任何识别出的文字内容。
enum Log {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceLayer", isDirectory: true)
    static let url = dir.appendingPathComponent("voicelayer.log")

    private static let queue = DispatchQueue(label: "voicelayer.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // 超过 1MB 就留最后一半，避免无限增长
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 1_000_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(data.count / 2).write(to: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            }
        }
    }

    /// 当前进程的物理内存占用（MB），与活动监视器里的“内存”一致。
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
