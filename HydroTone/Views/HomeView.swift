import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(PurchaseStore.self) private var purchases
    @Environment(DiagnosticsCenter.self) private var diagnostics
    @State private var showDiagnostics = false
    @State private var showPro = false
    @State private var selection: PhotosPickerItem?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var media: ImportedMedia?
    @State private var batch: BatchModel?
    @State private var loading = false
    @State private var importProgress: (done: Int, total: Int)?
    @State private var error: String?
    var body: some View {
        let pro = purchases.isPro
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Image(systemName: "water.waves").font(.system(size: 54)).foregroundStyle(.mint).accessibilityHidden(true)
                Text("Bring back\nthe dive.").font(.largeTitle.bold())
                Text("Natural color for your underwater photos and videos.").font(.title3).foregroundStyle(.secondary)
                Spacer()
                // Pro can pick up to BatchModel.maxPhotos; one photo still opens the single editor.
                PhotosPicker(selection: $photoSelection, maxSelectionCount: purchases.isPro ? BatchModel.maxPhotos : 1,
                             selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                    Label(pro ? "Select Photos" : "Select Photo", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                PhotosPicker(selection: $selection, matching: .videos, preferredItemEncoding: .current) {
                    Label("Select Video", systemImage: "video").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                if !purchases.isPro {
                    Button { showPro = true } label: {
                        Label(String(localized: "Batch correct up to \(BatchModel.maxPhotos) photos with Pro"), systemImage: "square.grid.2x2")
                            .font(.footnote)
                    }.frame(maxWidth: .infinity)
                }
                Text("Your media stays on your iPhone.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(28).navigationTitle("HydroTone")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { showDiagnostics = true } label: { Image(systemName: "info.circle").accessibilityLabel("Diagnostics") } }
                    ToolbarItem(placement: .topBarTrailing) { Button(purchases.isPro ? "Pro" : "Get Pro") { showPro = true } }
                }
                .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
                .sheet(isPresented: $showPro) { ProView() }
                .disabled(loading)
                .overlay {
                    if loading {
                        Group {
                            if let importProgress, importProgress.total > 1 {
                                ProgressView(String(localized: "Importing \(importProgress.done + 1) of \(importProgress.total)…"))
                            } else { ProgressView("Importing…") }
                        }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .navigationDestination(item: $media) { item in EditorView(media: item, diagnostics: diagnostics.recorder) }
                .navigationDestination(item: $batch) { model in BatchView(model: model) }
                .task(id: photoSelection) { await importPhotos() }
                .task(id: selection) {
                    guard let selection else { return }
                    loading = true
                    defer { loading = false }
                    do { media = try await SafeReadRetry().run(operation: .importing) { try await MediaImporter().load(selection) } }
                    catch is CancellationError { }
                    catch {
                        let failure = Failure.classify(error, operation: .importing)
                        await diagnostics.recorder.record(failure, operation: .importing)
                        if failure.kind != .cancelled { self.error = failure.message }
                    }
                    self.selection = nil
                }
                .alert("Couldn’t import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    /// One photo opens the single editor. Two or more open the batch screen.
    /// A photo that fails to import is skipped, so the rest of the selection survives.
    private func importPhotos() async {
        let items = photoSelection
        guard !items.isEmpty else { return }
        loading = true
        defer { loading = false; importProgress = nil; photoSelection = [] }
        var urls: [URL] = []
        var firstFailure: Failure?
        for (index, item) in items.enumerated() {
            importProgress = (index, items.count)
            do { urls.append(try await SafeReadRetry().run(operation: .importing) { try await MediaImporter().load(item) }.url) }
            catch is CancellationError { urls.forEach { TemporaryFiles.remove($0) }; return }
            catch {
                let failure = Failure.classify(error, operation: .importing)
                await diagnostics.recorder.record(failure, operation: .importing)
                if failure.kind != .cancelled, firstFailure == nil { firstFailure = failure }
            }
        }
        if urls.count == 1 { media = ImportedMedia(url: urls[0], kind: .photo) }
        else if urls.count > 1 { batch = BatchModel(urls: urls, diagnostics: diagnostics.recorder) }
        if let firstFailure {
            error = urls.isEmpty ? firstFailure.message
                : String(localized: "Couldn’t import \(items.count - urls.count) of \(items.count) selected.")
        }
    }
}
extension BatchModel: Hashable {
    nonisolated static func == (lhs: BatchModel, rhs: BatchModel) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
extension ImportedMedia: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
