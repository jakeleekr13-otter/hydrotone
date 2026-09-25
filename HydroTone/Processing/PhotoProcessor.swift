import CoreImage
import ImageIO
import UniformTypeIdentifiers
import os

enum PhotoPipelineVariant: String, CaseIterable, Sendable {
    case original, current, restoration, combined

    #if DEBUG
    static var selected: Self {
        let prefix = "--photo-pipeline="
        guard let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count),
              let variant = Self(rawValue: String(value)) else { return .combined }
        return variant
    }
    #endif
}

actor PhotoProcessor {
    let engine = FilterEngine()
    private let diagnostics: DiagnosticRecorder?
    private let depthEstimator = DepthEstimator()
    private let waterEstimator = WaterModelEstimator()
    private let restorationEngine = RestorationEngine()
    private var analyzedURL: URL?
    private var cachedAnalysis = WaterAnalysis.neutral
    private var restorationPlan: RestorationPlan?
    private var recordedRenderFallback = false
    #if DEBUG
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "photo-restoration")
    #endif

    init(diagnostics: DiagnosticRecorder? = nil) {
        self.diagnostics = diagnostics
    }

    func open(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]),
              image.extent.width > 0, image.extent.height > 0 else { throw HydroError.unreadable }
        return image
    }
    func analyze(_ url: URL) async throws -> WaterAnalysis {
        let source = engine.sdr(try open(url))
        return try await prepare(url: url, source: source)
    }
    func preview(_ url: URL, settings: FilterSettings, original: Bool) async throws -> CGImage {
        try Task.checkCancellation()
        let source = engine.sdr(try open(url))
        if !original, analyzedURL != url { _ = try await prepare(url: url, source: source) }
        let ratio = min(1, 1600 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        let result = original ? small : processed(small, settings: settings)
        guard let rendered = engine.context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace) else { throw HydroError.unreadable }
        return rendered
    }
    func export(_ url: URL, settings: FilterSettings) async throws -> URL {
        try Task.checkCancellation()
        let source = engine.sdr(try open(url))
        if analyzedURL != url { _ = try await prepare(url: url, source: source) }
        let image = processed(source, settings: settings)
        let target = try TemporaryFiles.makeURL(extension: "jpg")
        do {
            guard let cg = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw HydroError.exportFailed }
            // Bake orientation and retain capture date without copying stale thumbnails, dimensions or HDR gain maps.
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyOrientation: 1]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                var dates: [CFString: Any] = [:]
                for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] { dates[key] = exif[key] }
                properties[kCGImagePropertyExifDictionary] = dates
            }
            CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HydroError.exportFailed }
            try Task.checkCancellation()
            guard let check = CGImageSourceCreateWithURL(target as CFURL, nil), CGImageSourceGetCount(check) == 1,
                  let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil), decoded.width == cg.width, decoded.height == cg.height else { throw HydroError.invalidOutput }
            return target
        } catch { TemporaryFiles.remove(target); throw error }
    }

    #if DEBUG
    /// LLDB/tests can render all four variants without adding temporary production UI.
    func comparisonPreviews(_ url: URL, settings: FilterSettings) async throws -> [PhotoPipelineVariant: CGImage] {
        let source = engine.sdr(try open(url))
        _ = try await prepare(url: url, source: source)
        let ratio = min(1, 1600 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        var result: [PhotoPipelineVariant: CGImage] = [:]
        for variant in PhotoPipelineVariant.allCases {
            let image = processed(small, settings: settings, debugVariant: variant)
            if let rendered = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace) {
                result[variant] = rendered
            }
        }
        return result
    }
    #endif

    private func prepare(url: URL, source: CIImage) async throws -> WaterAnalysis {
        if analyzedURL == url { return cachedAnalysis }
        let analysis = engine.analyze(source)
        analyzedURL = url
        cachedAnalysis = analysis
        restorationPlan = nil
        recordedRenderFallback = false
        do {
            let depth = try await depthEstimator.estimate(image: source, sourceURL: url)
            try Task.checkCancellation()
            let plan = try waterEstimator.estimate(image: source, depth: depth, legacy: analysis, context: engine.context)
            restorationPlan = plan
            #if DEBUG
            logger.debug("Binf=(\(plan.backscatterInfinity.x),\(plan.backscatterInfinity.y),\(plan.backscatterInfinity.z)) betaD=(\(plan.betaDirect.x),\(plan.betaDirect.y),\(plan.betaDirect.z)) betaB=(\(plan.betaBackscatter.x),\(plan.betaBackscatter.y),\(plan.betaBackscatter.z)) confidence=\(plan.confidence) floorPixels=\(plan.transmissionFloorPixelPercentage)% maxGainPixels=\(plan.maximumGainPixelPercentage)%")
            #endif
        } catch is CancellationError {
            restorationPlan = nil
            analyzedURL = nil
            throw CancellationError()
        } catch {
            // Depth/model/fitting failures deliberately preserve the shipping HydroTone result.
            restorationPlan = nil
            if let diagnostics {
                await diagnostics.record(.restorationFallback(.photoAnalysis), operation: .photoRestoration)
            }
            #if DEBUG
            logger.debug("Depth-aware restoration unavailable; using current HydroTone correction")
            #endif
        }
        return analysis
    }

    private func processed(_ source: CIImage, settings: FilterSettings,
                           debugVariant: PhotoPipelineVariant? = nil) -> CIImage {
        let current = engine.apply(source, settings: settings)
        #if DEBUG
        let variant = debugVariant ?? PhotoPipelineVariant.selected
        #else
        let variant = PhotoPipelineVariant.combined
        #endif
        if variant == .original { return source }
        if variant == .current { return current }
        guard let plan = restorationPlan else { return current }
        do {
            let rawRestoration = try restorationEngine.restore(source, plan: plan)
            if variant == .restoration {
                return engine.blend(source, rawRestoration, amount: plan.confidence)
            }
            let amount = min(1, max(0, settings.intensity))
            guard settings.preset != .original, amount > 0 else { return source }
            let finished = engine.finishing(rawRestoration, settings: settings)
            let depthAware = engine.blend(source, finished, amount: amount)
            // Low-confidence fits approach the exact existing HydroTone output.
            return engine.blend(current, depthAware, amount: plan.confidence)
        } catch {
            if !recordedRenderFallback, let diagnostics {
                recordedRenderFallback = true
                Task { await diagnostics.record(.restorationFallback(.photoRender), operation: .photoRestoration) }
            }
            #if DEBUG
            logger.debug("Restoration render failed; using current HydroTone correction")
            #endif
            return current
        }
    }
}
