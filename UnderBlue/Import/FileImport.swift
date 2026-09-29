import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Imports from the Files app and picks up shares from the share extension.
enum FileImport {
    /// Every image type ImageIO decodes on this device, camera RAW included, plus every movie type AVFoundation opens.
    static let contentTypes: [UTType] = {
        let images = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
        let movies = AVURLAsset.audiovisualContentTypes.filter { $0.conforms(to: .movie) }
        return images + movies
    }()

    static func kind(of type: UTType?) -> ImportedMedia.Kind? {
        guard let type else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .photo }
        return nil
    }

    /// Copies a file picked in Files into the app's temporary folder.
    static func load(_ url: URL) async throws -> ImportedMedia {
        try await Task.detached(priority: .userInitiated) { try copy(url) }.value
    }

    private static func copy(_ url: URL) throws -> ImportedMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let kind = kind(of: type) else { throw UnderBlueError.unsupported }
        var copied: Result<URL, Error>?
        var coordination: NSError?
        // A coordinated read downloads an iCloud Drive file that is not on the iPhone yet.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
            copied = Result { try TemporaryFiles.copyImport(readable) }
        }
        if let coordination { throw coordination }
        guard let copied else { throw UnderBlueError.unreadable }
        return ImportedMedia(url: try copied.get(), kind: kind, originalName: url.lastPathComponent)
    }

    /// Takes the newest share from the extension's inbox and moves its files into the temporary folder.
    /// Returns nothing when the inbox is empty or the App Group is unavailable.
    static func takeShared() async -> (media: [ImportedMedia], failed: Int)? {
        await Task.detached(priority: .userInitiated) { () -> (media: [ImportedMedia], failed: Int)? in
            guard let root = try? SharedInbox.root(), let share = SharedInbox.takeNewest(at: root) else { return nil }
            defer { SharedInbox.remove(share.folder) }
            var media: [ImportedMedia] = []
            for item in share.items {
                guard let kind = kind(of: UTType(filenameExtension: item.url.pathExtension)),
                      let url = try? TemporaryFiles.adopt(item.url) else { continue }
                media.append(ImportedMedia(url: url, kind: kind, originalName: item.originalName))
            }
            return (media, share.items.count - media.count)
        }.value
    }
}
