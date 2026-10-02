import SwiftUI

/// The Help sheet: a short usage guide, then the diagnostics tools.
struct DiagnosticsView: View {
    @Environment(DiagnosticsCenter.self) private var diagnostics
    @Environment(PurchaseStore.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var report: URL?
    @State private var error: String?
    @State private var working = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    step(1, "Choose a photo or video, or import from Files. You can also share to UnderBlue from the Photos app.")
                    step(2, "Pick a look: Natural Dive, Tropical or Deep Dive. Intensity sets how strong it is.")
                    step(3, "Custom starts from the Natural Dive result. Adjust it with five sliders.")
                    step(4, "Tap Compare to see the original. In the photo editor, pinch or double-tap to zoom.")
                    step(5, "For a video, Play 3s plays three seconds from the current position, then returns.")
                    step(6, "Tap Export, then Save to Photos.")
                } header: { Text("Guide") } footer: {
                    Text("Results depend on the original. Very dark or very bright scenes may not look as you expect. The same goes for photos and videos that were already edited.")
                }
                Section {
                    Label(String(localized: "With Pro, select up to \(BatchModel.maxPhotos) photos to correct them together. Tap a photo to give it its own look."),
                          systemImage: "square.grid.2x2")
                    if !purchases.isPro {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Free: 1 photo export and 1 video export (first 10 seconds, up to 1080p SDR).")
                                Text("Failed or cancelled exports don’t use your trial.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "gift") }
                    }
                }
                Section {
                    Link(destination: URL(string: "mailto:\(Self.supportEmail)?subject=UnderBlue%20Support")!) {
                        Label { Text(verbatim: Self.supportEmail) } icon: { Image(systemName: "envelope") }
                    }
                    Link(destination: URL(string: "https://jakeleekr13-otter.github.io/underblue-support/support/")!) {
                        Label("Support website", systemImage: "safari")
                    }
                } header: { Text("Support") } footer: {
                    Text("Send photos, videos and diagnostic reports by email. Don’t attach them to a public GitHub issue.")
                }
                Section("Diagnostics") {
                    Text("Diagnostics stay on this iPhone. Nothing is sent automatically.")
                    Text("The report includes error codes and Apple performance diagnostics, which may contain approximate times and device, OS and app details. It excludes your photos, videos, filenames and location.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if let report {
                        ShareLink("Share diagnostic report", item: report)
                    } else {
                        Button("Prepare diagnostic report") {
                            working = true
                            Task {
                                defer { working = false }
                                do { report = try await diagnostics.recorder.exportReport() }
                                catch { self.error = String(localized: "Couldn’t prepare diagnostics. Please try again.") }
                            }
                        }.disabled(working)
                    }
                    if working { ProgressView() }
                    Button("Delete local diagnostics", role: .destructive) {
                        Task { await diagnostics.recorder.clear(); TemporaryFiles.remove(report); report = nil }
                    }.disabled(working)
                }
                Section { Text("For a crash, TestFlight and Xcode Organizer may provide a separate Apple crash report. Keep the app build and its debug symbols together.").font(.footnote).foregroundStyle(.secondary) }
                Section {
                    NavigationLink("Open-source licenses") { LicensesView() }
                }
            }.navigationTitle("Help").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onDisappear { TemporaryFiles.remove(report) }
                .alert("Couldn’t finish", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private static let supportEmail = "support@enheart.me"
    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        Label { Text(text) } icon: { Image(systemName: "\(number).circle").foregroundStyle(.mint) }
    }
}

/// The bundled depth model is Apple's Core ML version of Depth Anything V2 Small, under the
/// Apache License 2.0 (model card: huggingface.co/apple/coreml-depth-anything-v2-small). The license
/// asks that it ships with a copy of the license, so Help shows it in full.
struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("UnderBlue includes the following open-source software. Its license follows.")
                Text(verbatim: "Depth Anything V2 Small (Core ML)")
                    .font(.headline)
                Text(verbatim: "Depth Anything V2 by Lihe Yang et al. Core ML conversion by Apple (huggingface.co/apple/coreml-depth-anything-v2-small). Licensed under the Apache License, Version 2.0.")
                    .font(.footnote)
                Text(verbatim: Self.licenseText)
                    .font(.caption)
                    .textSelection(.enabled)
            }.padding()
        }.navigationTitle("Open-source licenses").navigationBarTitleDisplayMode(.inline)
    }
    private static let licenseText: String = {
        guard let url = Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "Apache License, Version 2.0: https://www.apache.org/licenses/LICENSE-2.0" }
        // The file wraps at 80 columns. On a phone that wraps again into ragged lines, so each
        // paragraph becomes one line. The words stay the same.
        return text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }()
}
