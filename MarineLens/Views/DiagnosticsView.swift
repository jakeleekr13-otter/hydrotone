import SwiftUI

struct DiagnosticsView: View {
    @Environment(DiagnosticsCenter.self) private var diagnostics
    @Environment(\.dismiss) private var dismiss
    @State private var report: URL?
    @State private var error: String?
    @State private var working = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
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
            }.navigationTitle("Diagnostics").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onDisappear { TemporaryFiles.remove(report) }
                .alert("Couldn’t finish", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }
}
