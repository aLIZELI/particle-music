import Accelerate
import Foundation

/// 一帧给渲染用的分析结果
struct SpectrumSnapshot {
    var bars: [Float]
    var level: Float
    var bass: Float
    var mid: Float
    var treble: Float
    var beat: Float

    static let empty = SpectrumSnapshot(
        bars: [Float](repeating: 0, count: AudioAnalyzer.barCount),
        level: 0, bass: 0, mid: 0, treble: 0, beat: 0
    )
}

/// 把任意音源的单声道采样转成 96 根对数频谱柱
final class AudioAnalyzer: @unchecked Sendable {
    static let barCount = 96
    static let fftSize = 2048

    private let lock = NSLock()
    private var store = SpectrumSnapshot.empty

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let ringSize = AudioAnalyzer.fftSize * 4
    private var ring: [Float]
    private var ringWrite = 0
    private var hop = 0
    private var sampleRate: Double = 48000

    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var bandRanges: [(Int, Int)] = []
    private var smoothed = [Float](repeating: 0, count: AudioAnalyzer.barCount)
    private var bassAverage: Float = 0.02
    private var lastBeatTime: CFAbsoluteTime = 0

    private let demoLock = NSLock()
    private var demoFlag = false

    /// 演示信号：不依赖任何音频权限，用来确认渲染 / 截图
    var demoMode: Bool {
        get {
            demoLock.lock()
            defer { demoLock.unlock() }
            return demoFlag
        }
        set {
            demoLock.lock()
            demoFlag = newValue
            demoLock.unlock()
        }
    }

    init() {
        log2n = vDSP_Length(log2(Double(AudioAnalyzer.fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("无法创建 FFT setup")
        }
        fftSetup = setup
        ring = [Float](repeating: 0, count: ringSize)
        window = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
        vDSP_hann_window(&window, vDSP_Length(AudioAnalyzer.fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
        real = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
        imag = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
        mags = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
        buildBands()
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// 96 根柱子对应的中心频率，调试用
    static func frequency(forBar index: Int) -> Double {
        let fmin = 36.0
        let fmax = 16000.0
        return fmin * pow(fmax / fmin, Double(index) / Double(barCount))
    }

    func reset() {
        lock.lock()
        ring = [Float](repeating: 0, count: ringSize)
        ringWrite = 0
        hop = 0
        smoothed = [Float](repeating: 0, count: AudioAnalyzer.barCount)
        bassAverage = 0.02
        store = .empty
        lock.unlock()
    }

    /// 音频线程调用，传单声道 Float 采样
    func push(_ mono: [Float], sampleRate rate: Double) {
        guard !mono.isEmpty else { return }

        if rate > 0, abs(rate - sampleRate) > 1 {
            sampleRate = rate
            buildBands()
            reset()
        }

        lock.lock()
        for value in mono {
            ring[ringWrite] = value
            ringWrite = (ringWrite + 1) % ringSize
        }
        hop += mono.count
        let shouldAnalyze = hop >= AudioAnalyzer.fftSize / 2
        if shouldAnalyze { hop = 0 }
        lock.unlock()

        if shouldAnalyze { analyze() }
    }

    func snapshot(now: TimeInterval) -> SpectrumSnapshot {
        if demoMode { return demoSnapshot(now: now) }
        lock.lock()
        defer { lock.unlock() }
        var copy = store
        copy.bars = Array(store.bars)
        return copy
    }

    // MARK: - 分析

    private func analyze() {
        let n = AudioAnalyzer.fftSize
        var frame = [Float](repeating: 0, count: n)

        lock.lock()
        var index = ringWrite - n
        if index < 0 { index += ringSize }
        for i in 0..<n { frame[i] = ring[(index + i) % ringSize] }
        lock.unlock()

        // 去直流
        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(n))
        var negativeMean = -mean
        vDSP_vsadd(frame, 1, &negativeMean, &frame, 1, vDSP_Length(n))

        // RMS 用加窗前的数据
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))

        // 加 Hann 窗
        frame.withUnsafeBufferPointer { fp in
            window.withUnsafeBufferPointer { wp in
                windowed.withUnsafeMutableBufferPointer { out in
                    guard let base = fp.baseAddress, let win = wp.baseAddress, let dst = out.baseAddress else { return }
                    vDSP_vmul(base, 1, win, 1, dst, 1, vDSP_Length(n))
                }
            }
        }

        // FFT
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                mags.withUnsafeMutableBufferPointer { mp in
                    guard let r = rp.baseAddress, let im = ip.baseAddress, let m = mp.baseAddress else { return }
                    var split = DSPSplitComplex(realp: r, imagp: im)
                    windowed.withUnsafeBufferPointer { fp in
                        guard let base = fp.baseAddress else { return }
                        base.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, m, 1, vDSP_Length(n / 2))
                }
            }
        }

        var bars = [Float](repeating: 0, count: AudioAnalyzer.barCount)
        let scale = Float(1.0 / Double(n))

        for i in 0..<AudioAnalyzer.barCount {
            let range = bandRanges[i]
            var peak: Float = 0
            for k in range.0..<range.1 { peak = max(peak, mags[k]) }

            // 归一化到 -72dB…-14dB，再给高频一点补偿
            let db = 20 * log10(max(peak * scale, 1e-8))
            var value = (db + 72) / 58
            value = min(1, max(0, value))
            let tilt = 1 + Float(i) / Float(AudioAnalyzer.barCount) * 0.9
            bars[i] = min(1, value * tilt)
        }

        let smoothGain: Float = 0.55
        let decayGain: Float = 0.12
        for i in 0..<AudioAnalyzer.barCount {
            let target = bars[i]
            let current = smoothed[i]
            let gain = target > current ? smoothGain : decayGain
            smoothed[i] = current + (target - current) * gain
        }

        let bassEnd = barIndex(forHz: 180)
        let midEnd = barIndex(forHz: 1600)
        let bass = average(smoothed, 0, max(1, bassEnd))
        let mid = average(smoothed, bassEnd, max(bassEnd + 1, midEnd))
        let treble = average(smoothed, midEnd, AudioAnalyzer.barCount)

        // 简单的低音鼓点检测
        bassAverage = bassAverage * 0.96 + bass * 0.04
        var beat: Float = 0
        let now = CFAbsoluteTimeGetCurrent()
        if bass > max(0.28, bassAverage * 1.35), now - lastBeatTime > 0.16 {
            beat = min(1, (bass - bassAverage) * 2.2 + 0.2)
            lastBeatTime = now
        }

        let level = min(1, max(0, rms * 3.6))

        lock.lock()
        store = SpectrumSnapshot(
            bars: smoothed,
            level: level,
            bass: bass,
            mid: mid,
            treble: treble,
            beat: beat
        )
        lock.unlock()
    }

    private func average(_ values: [Float], _ start: Int, _ end: Int) -> Float {
        let lo = max(0, min(values.count - 1, start))
        let hi = max(lo + 1, min(values.count, end))
        var sum: Float = 0
        for i in lo..<hi { sum += values[i] }
        return sum / Float(hi - lo)
    }

    private func barIndex(forHz hz: Double) -> Int {
        let fmin = 36.0
        let fmax = 16000.0
        let ratio = log(hz / fmin) / log(fmax / fmin)
        let index = Int(ratio * Double(AudioAnalyzer.barCount))
        return max(0, min(AudioAnalyzer.barCount - 1, index))
    }

    private func buildBands() {
        let binHz = sampleRate / Double(AudioAnalyzer.fftSize)
        let maxBin = AudioAnalyzer.fftSize / 2 - 1
        bandRanges.removeAll(keepingCapacity: true)
        for i in 0..<AudioAnalyzer.barCount {
            let f0 = 36.0 * pow(16000.0 / 36.0, Double(i) / Double(AudioAnalyzer.barCount))
            let f1 = 36.0 * pow(16000.0 / 36.0, Double(i + 1) / Double(AudioAnalyzer.barCount))
            var a = Int(f0 / binHz)
            var b = Int(f1 / binHz)
            a = max(1, min(maxBin, a))
            b = max(a + 1, min(maxBin + 1, b))
            bandRanges.append((a, b))
        }
    }

    // MARK: - 演示信号

    private func demoSnapshot(now: TimeInterval) -> SpectrumSnapshot {
        let phase = (now * 1.75).truncatingRemainder(dividingBy: 1)
        let kick = exp(-phase * 9)
        var bars = [Float](repeating: 0, count: AudioAnalyzer.barCount)

        for i in 0..<AudioAnalyzer.barCount {
            let x = Float(i) / Float(AudioAnalyzer.barCount)
            let bassBump = Float(kick) * exp(-x * 4) * 0.8
            let lowMid = 0.26 * exp(-pow((x - 0.22) * 9, 2)) * Float(0.6 + 0.4 * sin(now * 2.1))
            let highMid = 0.2 * exp(-pow((x - 0.55) * 11, 2)) * Float(0.6 + 0.4 * sin(now * 3.3 + 1))
            bars[i] = min(1, max(0, 0.14 + bassBump + lowMid + highMid))
        }

        return SpectrumSnapshot(
            bars: bars,
            level: Float(0.24 + kick * 0.22),
            bass: Float(kick),
            mid: 0.3,
            treble: 0.25,
            beat: kick > 0.78 ? 1 : 0
        )
    }
}
