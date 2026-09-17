import Foundation

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
    var resolution: Resolution = .source
    var range: Range = .sdr
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
struct StorageCheck {
    static func require(bytes: Int64) throws {
        let values = try TemporaryFiles.directory.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes + 100_000_000 { throw HydroError.storage }
    }
}
