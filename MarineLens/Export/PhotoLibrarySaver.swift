import Photos

struct PhotoLibrarySaver {
    /// `fileName` is the name Photos keeps for the asset (ExportNaming). Without it Photos uses the temporary file's name.
    func save(_ url: URL, kind: ImportedMedia.Kind, fileName: String? = nil) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw HydroError.permission }
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = fileName
            request.addResource(with: kind == .photo ? .photo : .video, fileURL: url, options: options)
        }
    }
}
