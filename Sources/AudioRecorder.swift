import AVFoundation

/// 采集麦克风，统一转成 16kHz / 单声道 / 16-bit PCM，停止时导出 WAV。
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples = [Int16]()
    private let lock = NSLock()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var running = false

    /// 音量回调，范围约 0...1，在音频线程触发。
    var onLevel: ((Float) -> Void)?

    static let maxSeconds: Double = 180

    func start() throws {
        guard !running else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "VoiceLayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer, inRate: inFormat.sampleRate)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    /// 停止并返回 (WAV 数据, 时长秒)。
    func stop() -> (wav: Data, duration: Double) {
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
        lock.lock()
        let pcm = samples
        samples.removeAll()
        lock.unlock()
        return (Self.wav(from: pcm, sampleRate: 16000), Double(pcm.count) / 16000.0)
    }

    var currentDuration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16000.0
    }

    private func process(_ buffer: AVAudioPCMBuffer, inRate: Double) {
        // 音量
        if let ch = buffer.floatChannelData?[0] {
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            onLevel?(min(1, rms * 8))
        }

        guard let converter = converter else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return }

        let n = Int(out.frameLength)
        guard n > 0, let p = out.int16ChannelData?[0] else { return }
        lock.lock()
        if Double(samples.count) / 16000.0 < Self.maxSeconds {
            samples.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        }
        lock.unlock()
    }

    private static func wav(from pcm: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = pcm.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + byteCount))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!)
        u32(UInt32(byteCount))
        pcm.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
}
