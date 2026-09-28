import Foundation

struct FilterSettings: Sendable, Equatable {
    var preset: DivePreset = .natural
    var intensity: Float = 0.8
    var analysis: WaterAnalysis = .neutral
    /// Used only by the Custom preset. Every other preset ignores them.
    var adjustments = CustomAdjustments()
    /// Custom has no intensity slider. It renders at this strength.
    static let customStrength: Float = 1
    /// The strength the pipelines blend with: the slider value, or customStrength for Custom.
    var appliedIntensity: Float { preset == .custom ? Self.customStrength : intensity }
}

/// The Custom preset's five sliders. Each is a position in -1...1 (shown as -100...+100).
/// Zero is the automatic result. ColorCorrection.make turns them into correction values.
struct CustomAdjustments: Sendable, Equatable {
    var brightness: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    var clarity: Float = 0
    var temperature: Float = 0
    static let zero = Self()
    /// Change at a full slider (position -1 or +1). Provisional: these caps will be re-measured.
    enum Caps {
        static let brightnessDown: Float = 0.25     // taken from midLift
        static let brightnessUp: Float = 0.075      // added to shadowLift
        static let contrastDown: Float = 0.10       // toneCurve
        static let contrastUp: Float = 0.02
        static let saturationDown: Float = 0.45     // saturation
        static let saturationUp: Float = 0.35       // times (1 - 0.6 x neon)
        static let clarityDown: Float = 1           // relative change of clarity and definition
        static let clarityUp: Float = 0.75
        static let temperature: Float = 1500        // kelvin added to warmth
    }
    /// Every position in -1...1. A value that is not finite becomes 0.
    var clamped: Self {
        func fix(_ x: Float) -> Float { x.isFinite ? min(1, max(-1, x)) : 0 }
        return Self(brightness: fix(brightness), contrast: fix(contrast), saturation: fix(saturation),
                    clarity: fix(clarity), temperature: fix(temperature))
    }
    /// Brightness, contrast and saturation up all brighten or add colour, so their positive parts share
    /// one budget: when their sum is above one, each positive part is scaled by 1 / sum.
    var budgeted: Self {
        var v = clamped
        let sum = max(0, v.brightness) + max(0, v.contrast) + max(0, v.saturation)
        guard sum > 1 else { return v }
        for key in [\Self.brightness, \.contrast, \.saturation] where v[keyPath: key] > 0 { v[keyPath: key] /= sum }
        return v
    }
}
