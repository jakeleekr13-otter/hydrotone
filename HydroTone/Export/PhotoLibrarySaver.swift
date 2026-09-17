import Photos

struct PhotoLibrarySaver {
    func save(_ url: URL, kind: ImportedMedia.Kind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw HydroError.permission }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: kind == .photo ? .photo : .video, fileURL: url, options: nil)
        }
    }
}
