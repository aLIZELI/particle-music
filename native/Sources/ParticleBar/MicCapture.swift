import AVFoundation

/// 备用音源：麦克风。适合没有屏幕录制权限、或者只想让环境声驱动的时候
final class MicCapture {
    private let engine = AVAudioEngine()
    private(set) var running = false
    var onAudio: (([Float], Double) -> Void)?
    var onError: ((Error) -> Void)?

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.unsupportedAudio
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let data = buffer.floatChannelData else { return }

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<frames { mono[frame] += samples[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { mono[frame] *= scale }

        onAudio?(mono, buffer.format.sampleRate)
    }
}
