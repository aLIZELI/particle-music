import SwiftUI

/// 四套配色，和网页版保持一致
enum PaletteID: String, CaseIterable {
    case aurora
    case lava
    case neon
    case ocean

    var title: String {
        switch self {
        case .aurora: return "极光"
        case .lava: return "熔岩"
        case .neon: return "霓虹"
        case .ocean: return "深海"
        }
    }

    var hueA: Double {
        switch self {
        case .aurora: return 165
        case .lava: return 4
        case .neon: return 318
        case .ocean: return 188
        }
    }

    var hueB: Double {
        switch self {
        case .aurora: return 278
        case .lava: return 56
        case .neon: return 196
        case .ocean: return 238
        }
    }

    /// 0...1 的色相，t 是横向位置
    func hue(t: Double, shift: Double = 0) -> Double {
        let h = hueA + (hueB - hueA) * t + shift * 18
        return ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
    }

    func color(t: Double, brightness: Double, opacity: Double) -> Color {
        Color(hue: hue(t: t), saturation: 0.82, brightness: brightness, opacity: opacity)
    }
}

enum SourceID: String, CaseIterable {
    case system
    case mic
    case demo

    var title: String {
        switch self {
        case .system: return "系统声音"
        case .mic: return "麦克风"
        case .demo: return "演示信号"
        }
    }
}

/// 轻量设置，UserDefaults 持久化
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var height: CGFloat {
        didSet { defaults.set(Double(height), forKey: "barHeight") }
    }

    var opacity: Double {
        didSet { defaults.set(opacity, forKey: "opacity") }
    }

    var palette: PaletteID {
        didSet { defaults.set(palette.rawValue, forKey: "palette") }
    }

    var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: "clickThrough") }
    }

    var source: SourceID {
        didSet { defaults.set(source.rawValue, forKey: "source") }
    }

    private init() {
        height = CGFloat(defaults.object(forKey: "barHeight") as? Double ?? 110)
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.9
        palette = PaletteID(rawValue: defaults.string(forKey: "palette") ?? "") ?? .aurora
        clickThrough = defaults.object(forKey: "clickThrough") as? Bool ?? true
        source = SourceID(rawValue: defaults.string(forKey: "source") ?? "") ?? .system
    }
}
