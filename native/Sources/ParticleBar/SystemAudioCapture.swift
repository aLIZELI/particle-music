import AudioToolbox
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied
    case unsupportedAudio
    case micDenied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "没有找到可用的显示器"
        case .permissionDenied:
            return "需要“屏幕与系统音频录制”权限"
        case .unsupportedAudio:
            return "音频格式无法识别"
        case .micDenied:
            return "麦克风权限被拒绝"
        case .failed(let message):
            return message
        }
    }
}

/// 用 ScreenCaptureKit 抓系统混音（不含本 App 自己的声音）
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "particlebar.system-audio", qos: .userInitiated)
    private var running = false

    var onAudio: (([Float], Double) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        if running { await stop() }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }

        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.showsCursor = false
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw Self.map(error)
        }

        self.stream = stream
        running = true
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        running = false
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }

        let asbd = asbdPointer.pointee
        guard (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32 else { return }

        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channels > 0, frames > 0 else { return }

        let listSize = MemoryLayout<AudioBufferList>.size + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
        var mono = [Float](repeating: 0, count: frames)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if nonInterleaved {
            let used = min(channels, buffers.count)
            for index in 0..<used {
                guard let data = buffers[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames { mono[frame] += data[frame] }
            }
            let scale = 1 / Float(max(1, used))
            for frame in 0..<frames { mono[frame] *= scale }
        } else {
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                mono[frame] = sum / Float(channels)
            }
        }

        onAudio?(mono, asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        running = false
        onError?(Self.map(error))
    }

    private static func map(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3801 {
            return CaptureError.permissionDenied
        }
        if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3802 {
            return CaptureError.failed("系统音频捕获启动失败，请重试")
        }
        return CaptureError.failed(nsError.localizedDescription)
    }
}
