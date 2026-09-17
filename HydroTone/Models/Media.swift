import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct ImportedMedia: Identifiable, Sendable {
    enum Kind: Sendable { case photo, video }
    let id = UUID()
    let url: URL
    let kind: Kind
}

struct MediaFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            MediaFile(url: try TemporaryFiles.copyImport(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            MediaFile(url: try TemporaryFiles.copyImport(received.file))
        }
    }
}

enum TemporaryFiles {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HydroTone", isDirectory: true)
    static func makeURL(extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
    static func copyImport(_ source: URL) throws -> URL {
        let bytes = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try StorageCheck.require(bytes: Int64(bytes))
        let target = try makeURL(extension: source.pathExtension)
        do { try FileManager.default.copyItem(at: source, to: target); return target }
        catch { remove(target); throw error }
    }
    static func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent() == directory else { return }
        try? FileManager.default.removeItem(at: url)
    }
    static func cleanPreviousSession() {
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > 24 * 60 * 60 { remove(url) }
        }
    }
}

enum HydroError: LocalizedError {
    case unreadable, unsupported, exportFailed, permission, storage, invalidOutput, trialUnavailable
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "This media couldn’t be opened. Try another photo or video.")
        case .unsupported: String(localized: "This media format isn’t supported on this device.")
        case .exportFailed: String(localized: "The export couldn’t finish. Please try again.")
        case .permission: String(localized: "Allow HydroTone to add to Photos in Settings, then try saving again.")
        case .storage: String(localized: "There isn’t enough free storage. Free up some space and try again.")
        case .invalidOutput: String(localized: "The exported file didn’t pass our quality checks. Nothing was saved.")
        case .trialUnavailable: String(localized: "Trial access couldn’t be checked securely. Please try again.")
        }
    }
}
