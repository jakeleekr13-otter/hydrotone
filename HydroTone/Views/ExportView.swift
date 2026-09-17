import SwiftUI

struct ExportView: View {
    @Environment(PurchaseStore.self) private var purchases
    @Environment(TrialStore.self) private var trial
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let metadata = model.metadata {
                    Section("Resolution") {
                        Picker("Resolution", selection: $model.options.resolution) {
                            ForEach(ExportOptions.Resolution.allCases) { resolution in
                                Text(resolution.localizedName).tag(resolution).disabled(!purchases.isPro && resolution == .source && max(metadata.displaySize.width, metadata.displaySize.height) > 1920)
                            }
                        }
                        Text(model.options.summary(for: metadata)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Color") {
                        Picker("Color", selection: $model.options.range) {
                            Text("SDR").tag(ExportOptions.Range.sdr)
                            Text("HDR").tag(ExportOptions.Range.hdr).disabled(!model.capability.hdrAvailable || !purchases.isPro)
                        }.pickerStyle(.segmented)
                        Text(model.capability.explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section { Text("Original resolution · SDR · JPEG"); Text("Wide color is preserved. HDR photo export is unavailable.").font(.footnote).foregroundStyle(.secondary) }
                }
                if !purchases.isPro {
                    Section("Free trial") {
                        Text(model.media.kind == .photo ? String(localized: "1 photo export. This uses your free photo.") : String(localized: "1 video export · first 10 seconds · up to 1080p SDR. This uses your free video."))
                            .accessibilityIdentifier(model.media.kind == .photo ? "photo-trial-description" : "video-trial-description")
                        Text("Failed or cancelled exports don’t use your trial.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section { Button("Export") { model.startExport(purchases: purchases, trial: trial) }.frame(maxWidth: .infinity) }
            }.navigationTitle("Export").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
struct ExportCompleteView: View {
    @Bindable var model: EditorModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle").font(.system(size: 54)).foregroundStyle(.mint)
                Text("Ready to save").font(.title2.bold())
                Text("Your export has been checked and is ready for Photos.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Save to Photos") { Task { await model.saveCompleted() } }.buttonStyle(.borderedProminent).disabled(model.saving)
                if model.saving { ProgressView("Saving…") }
                Button("Discard export", role: .destructive) { model.discardCompleted() }.disabled(model.saving)
            }.padding(30).navigationTitle("Export complete").navigationBarTitleDisplayMode(.inline)
                .alert("Couldn’t save", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }.interactiveDismissDisabled(model.saving).presentationDetents([.medium])
    }
}
