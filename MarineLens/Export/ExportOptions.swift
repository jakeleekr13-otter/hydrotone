import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExportOptions: Sendable {
    enum Resolution: String, CaseIterable, Identifiable, Sendable {
        case source = "Original resolution", hd = "1080p"
        var id: String { rawValue }
        var localizedName: String { String(localized: String.LocalizationValue(rawValue)) }
    }
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case sdr = "SDR", hdr = "HDR"
        var id: String { rawValue }
    }
    /// Photo file type. Both save at quality 1. Below it, ImageIO wrote JPEG with half-resolution colour (4:2:0).
    /// HEIC also keeps 10 bits per channel, so smooth water gradients don't band.
    enum PhotoFormat: String, CaseIterable, Identifiable, Sendable {
        case jpeg, heic
        var id: String { rawValue }
        var name: String { rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
        var type: UTType { self == .jpeg ? .jpeg : .heic }
        /// HEIC needs an encoder on this device. JPEG is always there.
        static let available: [Self] = allCases.filter {
            $0 == .jpeg || (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
        }
    }
    var resolution: Resolution = .source
    var range: Range = .sdr
    var photoFormat: PhotoFormat = .jpeg
    var durationLimit: Double?
    func size(for source: CGSize) -> CGSize {
        let scale = resolution == .hd ? min(1, 1920 / max(source.width, source.height), 1080 / min(source.width, source.height)) : 1
        // Encoders require even dimensions. Never enlarge the source.
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2), height: max(2, floor(source.height * scale / 2) * 2))
    }
    func summary(for metadata: VideoMetadata) -> String {
        let size = size(for: metadata.displaySize)
        let dynamicRange = String(localized: String.LocalizationValue(range.rawValue))
        return "\(Int(size.width)) × \(Int(size.height)) · \(dynamicRange) · HEVC" + (range == .hdr ? " · 10-bit" : "")
    }
}
/// The photo format last chosen in the editor or the batch screen. Both use it.
struct PhotoFormatStore {
    static let key = "photoFormat.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// JPEG when nothing is saved, the value is unknown, or this device can't write the saved format.
    func load() -> ExportOptions.PhotoFormat {
        guard let raw = defaults.string(forKey: Self.key), let format = ExportOptions.PhotoFormat(rawValue: raw),
              ExportOptions.PhotoFormat.available.contains(format) else { return .jpeg }
        return format
    }

    func save(_ format: ExportOptions.PhotoFormat) { defaults.set(format.rawValue, forKey: Self.key) }
}
struct StorageCheck {
    static func require(bytes: Int64) throws {
        let values = try TemporaryFiles.directory.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes + 100_000_000 { throw HydroError.storage }
    }
}
