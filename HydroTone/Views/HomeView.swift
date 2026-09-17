import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(PurchaseStore.self) private var purchases
    @State private var showPro = false
    @State private var selection: PhotosPickerItem?
    @State private var media: ImportedMedia?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Spacer()
                Image(systemName: "water.waves").font(.system(size: 54)).foregroundStyle(.mint).accessibilityHidden(true)
                Text("Bring back\nthe dive.").font(.largeTitle.bold())
                Text("Natural color for your underwater photos and videos.").font(.title3).foregroundStyle(.secondary)
                Spacer()
                PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                    Label("Select Photo", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
                PhotosPicker(selection: $selection, matching: .videos, preferredItemEncoding: .current) {
                    Label("Select Video", systemImage: "video").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
                Text("Your media stays on your iPhone.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(28).navigationTitle("HydroTone")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(purchases.isPro ? "Pro" : "Get Pro") { showPro = true } } }
                .sheet(isPresented: $showPro) { ProView() }
                .disabled(loading)
                .overlay { if loading { ProgressView("Importing…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
                .navigationDestination(item: $media) { item in EditorView(media: item) }
                .task(id: selection) {
                    guard let selection else { return }
                    loading = true
                    defer { loading = false }
                    do { media = try await MediaImporter().load(selection) }
                    catch is CancellationError { }
                    catch { self.error = HydroError.unreadable.localizedDescription }
                    self.selection = nil
                }
                .alert("Couldn’t import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}
extension ImportedMedia: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
