import SwiftUI
import AVKit

struct EditorView: View {
    @Environment(PurchaseStore.self) private var purchases
    @Environment(TrialStore.self) private var trial
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: EditorModel
    init(media: ImportedMedia, diagnostics: DiagnosticRecorder) { _model = State(initialValue: EditorModel(media: media, diagnostics: diagnostics)) }
    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 16) {
                    previewPanel
                    ScrollView { controls }.frame(width: min(330, geometry.size.width * 0.42))
                }
            } else {
                VStack(spacing: 16) {
                    previewPanel
                    ScrollView { controls }.frame(maxHeight: min(350, geometry.size.height * 0.48))
                }
            }
        }.disabled(model.exporting).padding(.bottom, 8)
            .navigationTitle("Edit").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(model.exporting)
            .task { await model.load() }
            .task(id: model.settings) { if !model.loading { await model.refreshPreview() } }
            .task(id: model.comparing) { if !model.loading { await model.refreshPreview() } }
            .onDisappear { model.close() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { model.playbackFailed($0) }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.cancelForBackground() } }
            .sheet(isPresented: $model.showPro) { ProView() }
            .sheet(isPresented: $model.showExportOptions, onDismiss: { model.optionsDismissing = false }) { ExportView(model: model) }
            .sheet(isPresented: Binding(get: { model.completedURL != nil && !model.optionsDismissing }, set: { if !$0 { model.discardCompleted() } })) {
                ExportCompleteView(model: model)
            }
            .overlay { if model.exporting { exportProgress } }
            .alert("Couldn’t finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
            .alert("HydroTone", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button("OK") { model.notice = nil } } message: { Text(model.notice ?? "") }
    }
    private var previewPanel: some View {
        ZStack {
            Color.black
            if model.media.kind == .video { VideoPlayer(player: model.player) }
            else if let preview = model.comparing ? model.originalPreview : model.preview {
                Image(decorative: preview, scale: 1).resizable().scaledToFit().accessibilityLabel("Photo preview")
            }
            if model.loading { ProgressView("Opening…") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
    private var controls: some View {
        @Bindable var model = model
        return VStack(spacing: 18) {
            if model.previewPaused { Button("Retry preview") { Task { await model.retryPreview() } } }
            if model.metadata?.isHDR == true { Text("HDR source · SDR preview").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(model.comparing ? String(localized: "Original") : model.settings.preset.localizedName).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { model.comparing.toggle() } label: { Label("Compare", systemImage: model.comparing ? "eye.fill" : "eye") }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .accessibilityValue(model.comparing ? "Original" : "Corrected")
                    .accessibilityHint("Show original media without correction")
            }.padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(DivePreset.allCases) { preset in
                        Button { model.settings.preset = preset } label: {
                            VStack(spacing: 8) {
                                Image(systemName: preset == .original ? "circle.lefthalf.filled" : "water.waves").font(.title2)
                                Text(preset.localizedName).font(.caption.weight(.medium))
                            }.frame(minWidth: 96, minHeight: 72).padding(.horizontal, 5)
                                .background(model.settings.preset == preset ? Color.mint.opacity(0.2) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(model.settings.preset == preset ? Color.mint : .clear))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.settings.preset == preset ? .isSelected : [])
                    }
                }.padding(.horizontal)
            }
            VStack {
                HStack { Text("Intensity"); Spacer(); Text(model.settings.intensity, format: .percent.precision(.fractionLength(0))).monospacedDigit() }
                Slider(value: $model.settings.intensity, in: 0...1).accessibilityLabel("Filter intensity")
                    .disabled(model.settings.preset == .original)
            }.padding(.horizontal)
            Button("Export") { Task { await model.requestExport(purchases: purchases, trial: trial) } }
                .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(!model.ready || model.exporting)
        }.padding(.bottom, 8)
    }
    private var exportProgress: some View {
        VStack(spacing: 20) {
            if model.media.kind == .video {
                ProgressView(value: model.progress).frame(width: 220)
                Text(model.progress >= 0.99
                     ? String(localized: "Checking your video…")
                     : String(localized: "Exporting \(Int(model.progress * 100))%"))
            } else { ProgressView("Exporting…") }
            Text("Keep HydroTone open until export finishes.").font(.footnote)
            Button("Cancel") { model.exportTask?.cancel() }.frame(minHeight: 44)
        }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
