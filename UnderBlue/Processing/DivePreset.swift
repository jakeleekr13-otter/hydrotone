import Foundation

// Immutable settings are shared by preview and export. Analysis never changes per video frame.
enum DivePreset: String, CaseIterable, Identifiable, Sendable {
    case original = "Original", natural = "Natural Dive"
    case tropical = "Tropical", deep = "Deep Dive"
    /// The user preset: the automatic (Natural) result plus the user's CustomAdjustments, at full strength.
    case custom = "Custom"
    var id: String { rawValue }
    var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
    var restoration: Float {
        switch self { case .original: 0; case .natural, .custom: 0.45; case .tropical: 0.55; case .deep: 0.62 }
    }
    var vibrance: Float {
        switch self { case .original: 0; case .natural, .custom: 0.18; case .tropical: 0.22; case .deep: 0.18 }
    }
    var castRemoval: Float {
        switch self { case .original: 0; case .natural, .custom: 0.16; case .tropical: 0.16; case .deep: 0.22 }
    }
    var contrast: Float {
        switch self { case .original: 1; case .natural, .custom: 1.04; case .tropical: 1.04; case .deep: 1.04 }
    }
    var saturation: Float {
        switch self { case .original: 1; case .natural, .custom: 1.08; case .tropical: 1.16; case .deep: 1.08 }
    }
    var clarity: Float {
        switch self { case .original: 0; case .natural, .custom: 0.16; case .tropical: 0.19; case .deep: 0.25 }
    }
    /// Colour temperature shift in kelvin for an underwater scene. A grey scene (scene-mean chroma
    /// 0.05 or less) gets none; the full shift applies from chroma 0.10.
    var warmth: Float {
        switch self { case .original, .natural, .deep, .custom: 0; case .tropical: 600 }
    }
    /// Scale on the water tone's chroma ceiling: below 1 calms neon water. The water tone holds the
    /// water's hue, so calmer water does not drift toward violet. (Scaling waterSaturation instead
    /// turned pale blue water lavender.)
    var waterChroma: Float {
        switch self { case .original, .natural, .tropical, .custom: 1; case .deep: 0.78 }
    }
    /// Extra shadow lift, added after the global contrast. Deep Dive lifts dark subjects further; Tropical
    /// a little, for a brighter sunlit look. A colorControls brightness offset for Tropical was tried and turned
    /// dark blue water indigo (29 Sep 2026: r05 violet pixels 10% to 16%).
    var shadowBoost: Float {
        switch self { case .original, .natural, .custom: 0; case .tropical: 0.08; case .deep: 0.20 }
    }
    /// OKLab hue the clear water is moved to. Natural Dive uses azure (ColorCorrection.waterHueGoal).
    /// Tropical leans to shallow turquoise. A bluer Deep Dive goal (252) was tried and turned reef and
    /// sea fans violet (29 Sep 2026: r02 39% of pixels, Natural 3%).
    var waterHue: Float {
        switch self { case .original, .natural, .deep, .custom: 240; case .tropical: 232 }
    }
    var symbolName: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .natural: "water.waves"
        case .tropical: "sun.max.fill"
        case .deep: "drop.fill"
        case .custom: "gearshape"
        }
    }
}
