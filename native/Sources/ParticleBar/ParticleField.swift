import Foundation

/// 顶部条里那些慢慢漂浮的小光点，比网页版少很多，避免抢戏
final class ParticleField {
    struct Particle {
        var x: Float
        var y: Float
        var vx: Float
        var vy: Float
        var size: Float
        var alpha: Float
        var phase: Float
    }

    private(set) var items: [Particle] = []
    private var lastTime: TimeInterval = 0
    private let capacity: Int

    init(count: Int = 140) {
        capacity = count
        items = (0..<count).map { _ in Self.randomParticle() }
    }

    private static func randomParticle() -> Particle {
        Particle(
            x: Float.random(in: 0...1),
            y: Float.random(in: 0...1),
            vx: Float.random(in: -0.012...0.012),
            vy: Float.random(in: -0.07 ... -0.02),
            size: Float.random(in: 0.7...2.1),
            alpha: Float.random(in: 0.2...0.55),
            phase: Float.random(in: 0...6.28)
        )
    }

    func update(now: TimeInterval, level: Float, bass: Float, beat: Float) {
        var dt = Float(now - lastTime)
        lastTime = now
        if !dt.isFinite { dt = 0 }
        dt = min(max(dt, 0), 0.05)
        guard dt > 0 else { return }

        for index in items.indices {
            var particle = items[index]
            let shimmer = sin(Float(now) * 0.35 + particle.phase) * 0.004
            particle.x += (particle.vx + shimmer) * dt
            particle.y += (particle.vy - bass * 0.05 - beat * 0.06) * dt
            particle.alpha = min(0.65, particle.alpha + level * 0.02 * dt)

            if particle.y < -0.06 {
                particle.y = 1.06
                particle.x = .random(in: 0...1)
                particle.alpha = .random(in: 0.12...0.4)
            }
            if particle.x < -0.05 { particle.x = 1.05 }
            if particle.x > 1.05 { particle.x = -0.05 }

            items[index] = particle
        }
        _ = capacity
    }
}
