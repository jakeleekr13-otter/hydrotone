import SwiftUI
import UniformTypeIdentifiers

/// UnderBlue in the share sheet. It copies the shared photos or video into the App Group inbox
/// (SharedInbox), then opens UnderBlue, which opens the share in the editor or the batch screen.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ShareView(model: model, open: { [weak self] in self?.openApp() },
                             done: { [weak self] in self?.done() }, cancel: { [weak self] in self?.cancel() })
        let host = UIHostingController(rootView: root.preferredColorScheme(.dark).tint(.mint))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.start(providers)
    }

    /// iOS has no public call for a share extension to open its app. The extension's UIApplication object is on
    /// the responder chain, so the extension asks it to open UnderBlue. If iOS refuses, the sheet stays open.
    private func openApp() {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIApplication) { responder = current.next }
        guard let application = responder as? UIApplication else { model.openFailed = true; return }
        application.open(SharedInbox.openURL, options: [:]) { [weak self] opened in
            if opened { self?.done() } else { self?.model.openFailed = true }
        }
    }

    private func done() { extensionContext?.completeRequest(returningItems: nil) }
    private func cancel() {
        model.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

@MainActor @Observable
final class ShareModel {
    enum State: Equatable { case copying, done(saved: Int, total: Int), failed }
    var state = State.copying
    /// iOS refused to open UnderBlue. The share still waits in the inbox for the next time UnderBlue opens.
    var openFailed = false
    private var task: Task<Void, Never>?

    func start(_ providers: [NSItemProvider]) {
        task = Task {
            do {
                let folder = try SharedInbox.beginShare(at: try SharedInbox.root())
                var saved = 0
                do {
                    for (index, provider) in providers.enumerated() {
                        try Task.checkCancellation()
                        do { try await Self.copy(provider, index: index, into: folder); saved += 1 }
                        catch is CancellationError { throw CancellationError() } catch { continue }
                    }
                    guard saved > 0 else { throw CocoaError(.fileReadUnknown) }
                    try SharedInbox.finish(folder)
                } catch { SharedInbox.remove(folder); throw error }
                state = .done(saved: saved, total: providers.count)
            } catch is CancellationError { } catch { state = .failed }
        }
    }

    func cancel() { task?.cancel() }

    /// Copies one item. The provider's file only exists inside its completion handler, so the copy happens there.
    nonisolated private static func copy(_ provider: NSItemProvider, index: Int, into folder: URL) async throws {
        // Providers list their best representation first. A Live Photo may lead with a type that is neither.
        guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) }) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let suggested = provider.suggestedName
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                    guard let url else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                    let name = SharedInbox.fileName(index: index, original: SharedInbox.originalName(suggested: suggested, file: url, type: type))
                    continuation.resume(with: Result { try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name)) })
                }
            }
        } catch {
            // Some apps share an image only as data, for example a screenshot that was marked up.
            guard type.conforms(to: .image) else { throw error }
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                _ = provider.loadDataRepresentation(for: type) { data, error in
                    continuation.resume(with: Result { guard let data else { throw error ?? CocoaError(.fileReadUnknown) }; return data })
                }
            }
            let name = SharedInbox.fileName(index: index, original: SharedInbox.originalName(suggested: suggested, file: nil, type: type))
            try data.write(to: folder.appendingPathComponent(name))
        }
    }
}

struct ShareView: View {
    let model: ShareModel
    let open: () -> Void
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch model.state {
                case .copying:
                    ProgressView("Adding to UnderBlue…")
                case .done(let saved, let total):
                    Image(systemName: "checkmark.circle").font(.system(size: 54)).foregroundStyle(.mint).accessibilityHidden(true)
                    Text("Added to UnderBlue").font(.title2.bold())
                    if saved < total { Text("Couldn’t add \(total - saved) of \(total).").font(.footnote).foregroundStyle(.secondary) }
                    if model.openFailed { Text("Open UnderBlue to edit.").foregroundStyle(.secondary) }
                    else { Button("Open UnderBlue", action: open).buttonStyle(.borderedProminent) }
                case .failed:
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 54)).foregroundStyle(.orange).accessibilityHidden(true)
                    Text("Couldn’t add to UnderBlue").font(.title2.bold())
                    Text("Open UnderBlue and import from Photos or Files instead.").foregroundStyle(.secondary)
                }
            }.multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("UnderBlue").navigationBarTitleDisplayMode(.inline)
                // When every item was added there is nothing to read here, so UnderBlue opens at once.
                // A partial share waits for the Open button, so the person sees what was left out.
                .onChange(of: model.state) { _, state in
                    if case .done(let saved, let total) = state, saved == total { open() }
                }
                .toolbar {
                    if model.state == .copying {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    } else {
                        ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                    }
                }
        }
    }
}
