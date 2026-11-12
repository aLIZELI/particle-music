import SwiftUI

/// 一帧横条画面：静态数据 + 时间，方便同时用于实时渲染和截图
struct StripCanvas: View {
    var snapshot: SpectrumSnapshot
    var time: TimeInterval
    var palette: PaletteID
    var particles: ParticleField

    var body: some View {
        Canvas { context, size in
            StripRenderer.draw(
                context: &context,
                size: size,
                snapshot: snapshot,
                time: time,
                palette: palette,
                particles: particles
            )
        }
    }
}

/// 实时版本：60fps 从分析器取最新频谱
struct StripView: View {
    let analyzer: AudioAnalyzer
    let particles: ParticleField
    let palette: PaletteID

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            StripCanvas(
                snapshot: analyzer.snapshot(now: now),
                time: now,
                palette: palette,
                particles: particles
            )
        }
    }
}

enum StripRenderer {
    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        snapshot: SpectrumSnapshot,
        time: TimeInterval,
        palette: PaletteID,
        particles: ParticleField
    ) {
        guard size.width > 12, size.height > 12 else { return }

        let level = CGFloat(clamp(snapshot.level))
        let bass = CGFloat(clamp(snapshot.bass))
        let treble = CGFloat(clamp(snapshot.treble))

        particles.update(now: time, level: Float(level), bass: Float(bass), beat: snapshot.beat)

        drawBackground(context: &context, size: size, palette: palette)
        drawBars(
            context: &context,
            size: size,
            snapshot: snapshot,
            palette: palette,
            level: level,
            treble: treble,
            time: time
        )
        drawParticles(context: &context, size: size, palette: palette, level: level, particles: particles)
        drawTopLine(context: &context, size: size)
    }

    private static func clamp(_ value: Float) -> Float {
        min(1, max(0, value))
    }

    private static func drawBackground(context: inout GraphicsContext, size: CGSize, palette: PaletteID) {
        let rect = Path(CGRect(origin: .zero, size: size))
        context.fill(rect, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color.black.opacity(0.5), location: 0),
                .init(color: Color.black.opacity(0.24), location: 0.5),
                .init(color: Color.black.opacity(0.0), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: size.height)
        ))
    }

    private static func drawBars(
        context: inout GraphicsContext,
        size: CGSize,
        snapshot: SpectrumSnapshot,
        palette: PaletteID,
        level: CGFloat,
        treble: CGFloat,
        time: TimeInterval
    ) {
        let count = min(104, max(46, Int(size.width / 18)))
        let margin = max(14, size.width * 0.012)
        let usable = size.width - margin * 2
        let slot = usable / CGFloat(count)
        let barWidth = max(2.2, slot * 0.55)
        let centerY = size.height * 0.54
        let maxHalf = size.height * 0.37

        for index in 0..<count {
            let t = Double(index) / Double(max(1, count - 1))
            let source = min(AudioAnalyzer.barCount - 1, Int(t * Double(AudioAnalyzer.barCount - 1)))
            let raw = CGFloat(snapshot.bars[source])
            let breathing = 0.016 + 0.01 * CGFloat(0.5 + 0.5 * sin(time * 0.7 + Double(index) * 0.22))
            let value = level < 0.035 ? max(raw, breathing) : max(raw, 0.018)

            let half = max(0.8, value * maxHalf)
            let x = margin + slot * CGFloat(index) + (slot - barWidth) / 2
            let edge = min(1, min(CGFloat(index), CGFloat(count - 1 - index)) / 10)
            let alpha = Double(min(1, (0.25 + value * 0.65) * edge))

            if value > 0.06 {
                let glowRect = CGRect(
                    x: x - barWidth * 1.2,
                    y: centerY - half - 2,
                    width: barWidth * 3.4,
                    height: half * 2 + 4
                )
                context.fill(
                    Path(roundedRect: glowRect, cornerRadius: barWidth * 1.7),
                    with: .color(palette.color(t: t, brightness: 0.9, opacity: alpha * 0.13))
                )
            }

            let coreRect = CGRect(x: x, y: centerY - half, width: barWidth, height: half * 2)
            let color = palette.color(
                t: t,
                brightness: min(1, Double(0.62 + value * 0.36 + treble * 0.04)),
                opacity: alpha
            )
            let shade = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0.3), location: 0),
                    .init(color: color, location: 0.5),
                    .init(color: color.opacity(0.3), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: centerY - half),
                endPoint: CGPoint(x: 0, y: centerY + half)
            )
            context.fill(Path(roundedRect: coreRect, cornerRadius: barWidth / 2), with: shade)
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: margin, y: centerY))
        baseline.addLine(to: CGPoint(x: size.width - margin, y: centerY))
        context.stroke(
            baseline,
            with: .color(palette.color(t: 0.5, brightness: 0.85, opacity: Double(0.08 + level * 0.2))),
            lineWidth: 1
        )
    }

    private static func drawParticles(
        context: inout GraphicsContext,
        size: CGSize,
        palette: PaletteID,
        level: CGFloat,
        particles: ParticleField
    ) {
        var particleContext = context
        particleContext.blendMode = .plusLighter

        for particle in particles.items {
            let x = CGFloat(particle.x) * size.width
            let y = CGFloat(particle.y) * size.height
            let dimension = max(0.8, CGFloat(particle.size) * 1.3)
            let opacity = min(0.9, Double(particle.alpha) * (0.55 + Double(level) * 0.55))
            let rect = CGRect(x: x, y: y, width: dimension, height: dimension)
            particleContext.fill(
                Path(ellipseIn: rect),
                with: .color(palette.color(t: Double(particle.x), brightness: 0.95, opacity: opacity))
            )
        }
    }

    private static func drawTopLine(context: inout GraphicsContext, size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: 0.5))
        line.addLine(to: CGPoint(x: size.width, y: 0.5))
        context.stroke(line, with: .color(Color.white.opacity(0.055)), lineWidth: 1)
    }
}
