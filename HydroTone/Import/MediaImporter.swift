import PhotosUI
import SwiftUI

struct MediaImporter {
    func load(_ item: PhotosPickerItem) async throws -> ImportedMedia {
        guard let file = try await item.loadTransferable(type: MediaFile.self) else { throw HydroError.unreadable }
        if Task.isCancelled { TemporaryFiles.remove(file.url); throw CancellationError() }
        let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        return ImportedMedia(url: file.url, kind: video ? .video : .photo)
    }
}
