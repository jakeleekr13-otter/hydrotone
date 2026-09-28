import Foundation

/// File names for saved results. Photos keeps this name and uses it when the file leaves the library.
///
/// - With a source name: `<source>_UnderBlue_<look>.<ext>`, for example `IMG_1234_UnderBlue_NaturalDive.jpg`.
/// - Without one: `UnderBlue_<yyyyMMdd_HHmmss>_<look>.<ext>`, using the export time.
/// - Re-editing a saved result replaces its look instead of stacking a second suffix.
enum ExportNaming {
    static let maxSourceLength = 64

    static func fileName(source: String?, preset: DivePreset, extension ext: String, date: Date = .now) -> String {
        let look = token(preset)
        guard let stem = stem(from: source) else { return "UnderBlue_\(timestamp(date))_\(look).\(ext)" }
        if stem.wholeMatch(of: timestampName) != nil { return "\(stem)_\(look).\(ext)" }
        return "\(stem)_UnderBlue_\(look).\(ext)"
    }

    /// The look in English without spaces, so names stay the same in every app language.
    static func token(_ preset: DivePreset) -> String { preset.rawValue.replacingOccurrences(of: " ", with: "") }

    /// The source name without extension or an earlier UnderBlue suffix, safe on common file systems.
    /// Nil when nothing useful is left, including the UUID names of temporary copies.
    static func stem(from source: String?) -> String? {
        guard let source else { return nil }
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let scalars = (source as NSString).deletingPathExtension.unicodeScalars.map { unsafe.contains($0) ? "_" : $0 }
        var stem = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: trimmed)
        guard !stem.isEmpty, UUID(uuidString: stem) == nil else { return nil }
        for preset in DivePreset.allCases {
            let look = token(preset)
            if stem.hasSuffix("_UnderBlue_" + look) { stem.removeLast(("_UnderBlue_" + look).count); break }
            if stem.hasSuffix("_" + look), stem.dropLast(look.count + 1).wholeMatch(of: timestampName) != nil {
                stem.removeLast(look.count + 1); break
            }
        }
        stem = String(stem.prefix(maxSourceLength)).trimmingCharacters(in: trimmed)
        return stem.isEmpty ? nil : stem
    }

    private static let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._"))
    private static var timestampName: Regex<Substring> { /UnderBlue_\d{8}_\d{6}/ }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }
}
