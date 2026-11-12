import AppKit
import SwiftUI

let arguments = CommandLine.arguments

func argumentValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func paletteFromArguments() -> PaletteID {
    if let raw = argumentValue("--palette"), let palette = PaletteID(rawValue: raw) {
        return palette
    }
    return .aurora
}

// MARK: - 自检：把几个测试音送进分析器，检查频段映射

func runSelfTest() {
    let analyzer = AudioAnalyzer()
    let sampleRate = 48000.0
    let tones: [Double] = [100, 1000, 8000]

    for tone in tones {
        analyzer.reset()
        let count = Int(sampleRate * 0.6)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            samples[index] = 0.1 * Float(sin(2 * Double.pi * tone * Double(index) / sampleRate))
        }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1024, samples.count)
            analyzer.push(Array(samples[offset..<end]), sampleRate: sampleRate)
            offset = end
        }

        let snapshot = analyzer.snapshot(now: 0)
        var peakIndex = 0
        var peakValue: Float = 0
        for (index, value) in snapshot.bars.enumerated() where value > peakValue {
            peakValue = value
            peakIndex = index
        }
        let center = AudioAnalyzer.frequency(forBar: peakIndex)
        let target = tones.min(by: { abs($0 - center) < abs($1 - center) }) ?? 0
        let mark = abs(center - target) < max(120, target * 0.25) ? "✓" : "⚠"
        print(String(
            format: "%@ %6.0f Hz → 第 %2d 根柱 (≈%5.0f Hz) 强度 %.2f   bass %.2f  mid %.2f  treble %.2f  level %.2f",
            mark, tone, peakIndex, center, peakValue,
            snapshot.bass, snapshot.mid, snapshot.treble, snapshot.level
        ))
    }
}

// MARK: - 离屏截图：不依赖屏幕录制权限，用来检查横条的渲染

@MainActor
func runSnapshot(path: String, palette: PaletteID, width: CGFloat, height: CGFloat) {
    _ = NSApplication.shared

    let analyzer = AudioAnalyzer()
    analyzer.demoMode = true
    let time: TimeInterval = 0.02
    let particles = ParticleField()
    let canvas = StripCanvas(
        snapshot: analyzer.snapshot(now: time),
        time: time,
        palette: palette,
        particles: particles
    )
    .frame(width: width, height: height)

    let renderer = ImageRenderer(content: canvas)
    renderer.scale = 2

    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("snapshot: 渲染失败\n".utf8))
        return
    }

    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("snapshot 已保存：\(path) (\(Int(width))×\(Int(height)))")
    } catch {
        FileHandle.standardError.write(Data("snapshot: 写入失败 \(error)\n".utf8))
    }
}

// MARK: - 入口

if arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

if let path = argumentValue("--snapshot") {
    let width = argumentValue("--width").flatMap { Double($0) }.map { CGFloat($0) } ?? 1600
    let height = argumentValue("--height").flatMap { Double($0) }.map { CGFloat($0) } ?? 110
    Task { @MainActor in
        runSnapshot(path: path, palette: paletteFromArguments(), width: width, height: height)
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
