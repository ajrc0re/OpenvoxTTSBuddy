import AVFoundation

/// Plays audio chunks as they arrive from a streaming request.
@MainActor
final class StreamingAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var pcmFormat: PCMFormat?
    private var leftover = Data()
    private var pendingBuffers = 0
    private var inputFinished = false
    private var generation = 0
    private var onFinished: (() -> Void)?

    /// Everything received so far, so the clip can be saved afterwards.
    private(set) var receivedPCM = Data()
    var receivedFormat: PCMFormat? { pcmFormat }

    var volume: Float = 1 {
        didSet { node.volume = volume }
    }

    init() {
        engine.attach(node)
    }

    func begin(onFinished: @escaping () -> Void) {
        stop()
        self.onFinished = onFinished
    }

    func enqueue(_ chunk: Data) throws {
        var pcm: Data
        if let parsed = WAV.parse(chunk) {
            pcmFormat = parsed.format
            pcm = parsed.pcm
        } else {
            if pcmFormat == nil { pcmFormat = .fallback }
            pcm = chunk
        }
        guard let format = pcmFormat else { return }

        if !leftover.isEmpty {
            pcm = leftover + pcm
            leftover.removeAll()
        }
        let usable = pcm.count - pcm.count % format.bytesPerFrame
        if usable < pcm.count {
            leftover = pcm.subdata(in: pcm.startIndex + usable..<pcm.endIndex)
            pcm = pcm.subdata(in: pcm.startIndex..<pcm.startIndex + usable)
        }
        guard !pcm.isEmpty, let buffer = Self.makeBuffer(pcm: pcm, format: format) else { return }
        receivedPCM.append(pcm)

        try connect(buffer.format)
        pendingBuffers += 1
        let token = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.pendingBuffers -= 1
                self.finishIfDone()
            }
        }
        if !node.isPlaying { node.play() }
    }

    /// Call once the network stream has ended; `onFinished` fires after the
    /// last scheduled buffer has played.
    func finishInput() {
        inputFinished = true
        finishIfDone()
    }

    func stop() {
        generation += 1
        node.stop()
        engine.stop()
        pendingBuffers = 0
        inputFinished = false
        leftover.removeAll()
        receivedPCM = Data()
        pcmFormat = nil
        onFinished = nil
    }

    private func finishIfDone() {
        guard inputFinished, pendingBuffers <= 0 else { return }
        let callback = onFinished
        onFinished = nil
        callback?()
    }

    private func connect(_ format: AVAudioFormat) throws {
        if connectedFormat != format {
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        node.volume = volume
    }

    /// Converts interleaved little-endian PCM into a deinterleaved Float32 buffer.
    private static func makeBuffer(pcm: Data, format: PCMFormat) -> AVAudioPCMBuffer? {
        let channels = format.channels
        let frames = pcm.count / format.bytesPerFrame
        guard frames > 0,
              let avFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                           channels: AVAudioChannelCount(channels), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let bytesPerSample = format.bitsPerSample / 8
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frames {
                for ch in 0..<channels {
                    let i = (frame * channels + ch) * bytesPerSample
                    let sample: Float
                    switch (bytesPerSample, format.isFloat) {
                    case (4, true):
                        sample = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian)
                    case (8, true):
                        sample = Float(Double(bitPattern: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian))
                    case (1, _):
                        sample = (Float(raw[i]) - 128) / 128
                    case (2, _):
                        sample = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))) / 32_768
                    case (3, _):
                        let v = Int32(raw[i]) | Int32(raw[i + 1]) << 8 | Int32(Int8(bitPattern: raw[i + 2])) << 16
                        sample = Float(v) / 8_388_608
                    case (4, false):
                        sample = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int32.self))) / 2_147_483_648
                    default:
                        sample = 0
                    }
                    out[ch][frame] = sample
                }
            }
        }
        return buffer
    }
}
