import AVFoundation
import CoreImage
import Synchronization

private final class VideoRestorationDiagnosticGate: Sendable {
    private let recordedRenderFallback = Mutex(false)

    func recordRenderFallback(using diagnostics: DiagnosticRecorder?) {
        let shouldRecord = recordedRenderFallback.withLock { recorded in
            defer { recorded = true }
            return !recorded
        }
        guard shouldRecord, let diagnostics else { return }
        Task {
            await diagnostics.record(.restorationFallback(.videoRender),
                                     operation: .videoRestoration)
        }
    }
}

final class PreviewSettings: Sendable {
    private let state = Mutex((settings: FilterSettings(), original: false))
    func update(_ settings: FilterSettings, comparing: Bool) {
        state.withLock { $0 = (settings, comparing) }
    }
    func snapshot() -> (FilterSettings, Bool) {
        state.withLock { ($0.settings, $0.original) }
    }
}

struct PreviewGeneration: Sendable, Equatable {
    private(set) var value: UInt64 = 0
    mutating func begin() -> UInt64 { value &+= 1; return value }
    func accepts(_ candidate: UInt64) -> Bool { candidate == value }
}

#if DEBUG
enum VideoDebugVariant: String, CaseIterable, Sendable {
    case original, current, restoration, combined, depth, confidence
}
#endif

struct VideoPreview {
    let engine = FilterEngine()
    let restorationEngine = RestorationEngine()
    let analyzer: VideoRestorationAnalyzer
    private let diagnostics: DiagnosticRecorder?
    private let diagnosticGate = VideoRestorationDiagnosticGate()

    init(diagnostics: DiagnosticRecorder? = nil) {
        self.diagnostics = diagnostics
        analyzer = VideoRestorationAnalyzer(diagnostics: diagnostics)
    }

    func analyze(_ url: URL, metadata: VideoMetadata) async throws -> VideoRestorationAnalysis {
        try await analyzer.analyze(url: url, metadata: metadata)
    }

    func item(_ url: URL, settings: PreviewSettings, analysis: VideoRestorationAnalysis? = nil) async throws -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.appliesPerFrameHDRDisplayMetadata = false
        item.videoComposition = try await composition(asset: asset, settings: settings, analysis: analysis)
        return item
    }

    /// A fresh composition is intentionally created for every preset revision.
    /// Reassigning a copied private CI composition does not reliably invalidate AVPlayer's rendered-frame cache.
    func composition(asset: AVAsset, settings: PreviewSettings,
                     analysis: VideoRestorationAnalysis? = nil) async throws -> AVVideoComposition {
        // nonisolated(nonsending): the non-Sendable asset never leaves the caller's isolation.
        let filtered = try await AVVideoComposition(applyingFiltersTo: asset) { [engine, restorationEngine, diagnosticGate, diagnostics] request in
            let (current, original) = settings.snapshot()
            guard !original else { return AVCIImageFilteringResult(resultImage: request.sourceImage, ciContext: engine.context) }
            let fallback = engine.apply(request.sourceImage, settings: current)
            guard let plan = analysis?.previewPlan(at: request.compositionTime.seconds) else {
                return AVCIImageFilteringResult(resultImage: fallback, ciContext: engine.context)
            }
            let output: CIImage
            do {
                output = try restorationEngine.combined(request.sourceImage, plan: plan,
                                                         settings: current, filter: engine)
            } catch {
                diagnosticGate.recordRenderFallback(using: diagnostics)
                output = fallback
            }
            return AVCIImageFilteringResult(resultImage: output, ciContext: engine.context)
        }
        // The filtering initializer takes no color options, so tag SDR Rec. 709 output on a copy.
        guard let composition = filtered.mutableCopy() as? AVMutableVideoComposition else { return filtered }
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    #if DEBUG
    func comparisonPreviews(analysis: VideoRestorationAnalysis, settings: FilterSettings) throws
        -> [VideoDebugVariant: CGImage] {
        let source = CIImage(cgImage: analysis.representativeFrame)
        let ratio = min(1, 1200 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        let current = engine.apply(small, settings: settings)
        var images: [VideoDebugVariant: CIImage] = [.original: small, .current: current]
        if let plan = analysis.previewPlan(at: analysis.representativeTime),
           let restored = try? restorationEngine.restore(small, plan: plan) {
            images[.restoration] = engine.blend(small, restored, amount: plan.confidence)
            images[.combined] = (try? restorationEngine.combined(small, plan: plan,
                                                                 settings: settings, filter: engine)) ?? current
            images[.depth] = depthVisualization(plan.depth, extent: small.extent)
            let weights = plan.effectiveChannelWeights
            images[.confidence] = CIImage(color: CIColor(red: CGFloat(weights.x), green: CGFloat(weights.y),
                                                         blue: CGFloat(weights.z), alpha: 1)).cropped(to: small.extent)
        } else {
            images[.restoration] = current; images[.combined] = current
        }
        var result: [VideoDebugVariant: CGImage] = [:]
        for (variant, image) in images {
            if let cg = engine.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                     colorSpace: FilterEngine.photoSpace) { result[variant] = cg }
        }
        return result
    }

    private func depthVisualization(_ map: NormalizedDepthMap, extent: CGRect) -> CIImage {
        var rgba = [Float](repeating: 0, count: map.values.count * 4)
        for index in map.values.indices {
            let value = map.values[index]
            rgba[index * 4] = value; rgba[index * 4 + 1] = value
            rgba[index * 4 + 2] = value; rgba[index * 4 + 3] = 1
        }
        let data = rgba.withUnsafeMutableBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: map.width * 16,
                            size: CGSize(width: map.width, height: map.height), format: .RGBAf,
                            colorSpace: FilterEngine.workingSpace)
        return image.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(map.width),
                                                        y: extent.height / CGFloat(map.height))).cropped(to: extent)
    }
    #endif
}
