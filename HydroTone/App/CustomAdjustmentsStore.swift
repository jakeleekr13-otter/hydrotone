import Foundation

/// The one saved slot of Custom slider positions. Only the five positions are stored, never a
/// DivePreset (its rawValue is a localization key and may change). Missing or broken data gives zero.
struct CustomAdjustmentsStore {
    static let key = "customAdjustments.v1"
    static let version = 1
    /// Double, so a number too large for Float still decodes; it then becomes infinite and so 0.
    private struct Stored: Codable {
        var version: Int
        var brightness: Double?
        var contrast: Double?
        var saturation: Double?
        var clarity: Double?
        var temperature: Double?
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> CustomAdjustments {
        let decoder = JSONDecoder()
        // Accept written-out non-finite numbers, so they become 0 instead of failing the whole slot.
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? decoder.decode(Stored.self, from: data), stored.version == Self.version else { return .zero }
        func value(_ x: Double?) -> Float { Float(x ?? 0) }
        return CustomAdjustments(brightness: value(stored.brightness), contrast: value(stored.contrast),
                                 saturation: value(stored.saturation), clarity: value(stored.clarity),
                                 temperature: value(stored.temperature)).clamped
    }

    func save(_ adjustments: CustomAdjustments) {
        let v = adjustments.clamped
        let stored = Stored(version: Self.version, brightness: Double(v.brightness), contrast: Double(v.contrast),
                            saturation: Double(v.saturation), clarity: Double(v.clarity), temperature: Double(v.temperature))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
