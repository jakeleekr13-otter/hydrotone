import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(PurchaseStore.self) private var purchases
    @Environment(DiagnosticsCenter.self) private var diagnostics
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDiagnostics = false
    @State private var showPro = false
    @State private var selection: PhotosPickerItem?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var pickedFiles: [URL] = []
    @State private var media: ImportedMedia?
    @State private var batch: BatchModel?
    @State private var loading = false
    @State private var importProgress: (done: Int, total: Int)?
    @State private var error: String?
    @State private var errorTitle = String(localized: "Couldn’t import")
    var body: some View {
        let pro = purchases.isPro
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Image(systemName: "water.waves").font(.system(size: 54)).foregroundStyle(.mint).accessibilityHidden(true)
                // Keeps every line: with three import buttons the Spacers shrink instead of the text.
                Text("Bring back\nthe dive.").font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                Text("Natural color for your underwater photos and videos.").font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                // Pro can pick up to BatchModel.maxPhotos; one photo still opens the single editor.
                PhotosPicker(selection: $photoSelection, maxSelectionCount: purchases.isPro ? BatchModel.maxPhotos : 1,
                             selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                    Label(pro ? "Select Photos" : "Select Photo", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                PhotosPicker(selection: $selection, matching: .videos, preferredItemEncoding: .current) {
                    Label("Select Video", systemImage: "video").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                Button { showFileImporter = true } label: {
                    Label("Import from Files", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                if !purchases.isPro {
                    Button { showPro = true } label: {
                        Label(String(localized: "Batch correct up to \(BatchModel.maxPhotos) photos with Pro"), systemImage: "square.grid.2x2")
                            .font(.footnote)
                    }.frame(maxWidth: .infinity)
                }
                Text("Your media stays on your iPhone.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(28).navigationTitle("MarineLens")
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
                .fileImporter(isPresented: $showFileImporter, allowedContentTypes: FileImport.contentTypes,
                              allowsMultipleSelection: purchases.isPro) { result in
                    switch result {
                    case .success(let urls): pickedFiles = urls
                    case .failure(let error): Task { await report(error) }
                    }
                }
                .task(id: pickedFiles) { await importFiles() }
                .task { await openShared() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await openShared() } } }
                // A share that arrived while an editor was open waits until the person comes back here.
                .onChange(of: media == nil && batch == nil) { _, home in if home { Task { await openShared() } } }
                .task(id: selection) {
                    guard let selection else { return }
                    loading = true
                    defer { loading = false }
                    do { media = try await SafeReadRetry().run(operation: .importing) { try await MediaImporter().load(selection) } }
                    catch is CancellationError { }
                    catch { await report(error) }
                    self.selection = nil
                }
                .alert(errorTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    /// One photo opens the single editor. Two or more open the batch screen.
    /// A photo that fails to import is skipped, so the rest of the selection survives.
    private func importPhotos() async {
        let items = photoSelection
        guard !items.isEmpty else { return }
        loading = true
        defer { loading = false; importProgress = nil; photoSelection = [] }
        var imported: [ImportedMedia] = []
        var firstFailure: Failure?
        for (index, item) in items.enumerated() {
            importProgress = (index, items.count)
            do { imported.append(try await SafeReadRetry().run(operation: .importing) { try await MediaImporter().load(item) }) }
            catch is CancellationError { imported.forEach { TemporaryFiles.remove($0.url) }; return }
            catch {
                let failure = Failure.classify(error, operation: .importing)
                await diagnostics.recorder.record(failure, operation: .importing)
                if failure.kind != .cancelled, firstFailure == nil { firstFailure = failure }
            }
        }
        finish(imported, selected: items.count, firstFailure: firstFailure)
    }

    /// Files can hold photos and videos together; the same rules as the Photos picker apply (`open`).
    private func importFiles() async {
        let urls = pickedFiles
        guard !urls.isEmpty else { return }
        loading = true
        defer { loading = false; importProgress = nil; pickedFiles = [] }
        var imported: [ImportedMedia] = []
        var firstFailure: Failure?
        for (index, url) in urls.enumerated() {
            importProgress = (index, urls.count)
            do { imported.append(try await FileImport.load(url)) }
            catch is CancellationError { imported.forEach { TemporaryFiles.remove($0.url) }; return }
            catch {
                let failure = Failure.classify(error, operation: .importing)
                await diagnostics.recorder.record(failure, operation: .importing)
                if failure.kind != .cancelled, firstFailure == nil { firstFailure = failure }
            }
        }
        finish(imported, selected: urls.count, firstFailure: firstFailure)
    }

    /// Opens the newest share from the share extension. It waits while an editor or the batch screen is open,
    /// so a share never replaces work in progress.
    private func openShared() async {
        guard media == nil, batch == nil, !loading else { return }
        loading = true
        defer { loading = false }
        guard let shared = await FileImport.takeShared() else { return }
        let failure = shared.failed > 0 ? Failure.classify(HydroError.unreadable, operation: .importing) : nil
        if let failure { await diagnostics.recorder.record(failure, operation: .importing) }
        finish(shared.media, selected: shared.media.count + shared.failed, firstFailure: failure)
    }

    private func finish(_ imported: [ImportedMedia], selected: Int, firstFailure: Failure?) {
        let notices = open(imported)
        var lines: [String] = []
        if let firstFailure {
            lines.append(imported.isEmpty ? firstFailure.message
                : String(localized: "Couldn’t import \(selected - imported.count) of \(selected) selected."))
        }
        lines += notices
        guard !lines.isEmpty else { return }
        errorTitle = firstFailure != nil ? String(localized: "Couldn’t import") : String(localized: "Some items weren’t opened")
        error = lines.joined(separator: "\n")
    }

    /// One item opens the editor. Several photos open the batch screen, up to BatchModel.maxPhotos with Pro
    /// and one photo without it. Videos open one at a time, so other videos in a multi-item import are skipped.
    /// Returns a line for each rule that dropped something.
    private func open(_ imported: [ImportedMedia]) -> [String] {
        var photos = imported.filter { $0.kind == .photo }
        var videos = imported.filter { $0.kind == .video }
        var notices: [String] = []
        if photos.isEmpty, !videos.isEmpty { media = videos.removeFirst() }
        if !videos.isEmpty {
            videos.forEach { TemporaryFiles.remove($0.url) }
            notices.append(String(localized: "Skipped videos: \(videos.count). Videos open one at a time."))
        }
        let limit = purchases.isPro ? BatchModel.maxPhotos : 1
        if photos.count > limit {
            photos[limit...].forEach { TemporaryFiles.remove($0.url) }
            photos = Array(photos.prefix(limit))
            notices.append(purchases.isPro ? String(localized: "Only the first \(limit) photos were opened.")
                : String(localized: "Only the first photo was opened. Pro can batch correct up to \(BatchModel.maxPhotos) photos."))
        }
        if photos.count == 1 { media = photos[0] }
        else if photos.count > 1 { batch = BatchModel(media: photos, diagnostics: diagnostics.recorder) }
        return notices
    }

    private func report(_ error: Error) async {
        let failure = Failure.classify(error, operation: .importing)
        await diagnostics.recorder.record(failure, operation: .importing)
        guard failure.kind != .cancelled else { return }
        errorTitle = String(localized: "Couldn’t import")
        self.error = failure.message
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
