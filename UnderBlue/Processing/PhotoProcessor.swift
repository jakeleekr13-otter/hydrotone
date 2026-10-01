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
    private let photoHDR = PhotoHDR()
    private struct Prepared { let analysis: WaterAnalysis; let plan: RestorationPlan? }
    /// Keyed by photo so a batch can switch between photos without repeating depth analysis.
    private var prepared: [URL: Prepared] = [:]
    private var recordedRenderFallback = false
    private var recordedKernelFallback = false
    #if DEBUG
    private let logger = Logger(subsystem: "com.underblue.app", category: "photo-restoration")
    #endif

    init(diagnostics: DiagnosticRecorder? = nil) {
        self.diagnostics = diagnostics
    }

    func open(_ url: URL) throws -> CIImage {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true { return try openRAW(url) }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true, .expandToHDR: true]),
              image.extent.width > 0, image.extent.height > 0 else { throw UnderBlueError.unreadable }
        return image
    }
    /// Camera RAW needs CIRAWFilter. On iOS, CIImage(contentsOf:) returned only the small embedded
    /// preview (1616 px long side for a 5472 px Sony ARW). The filter's default output is Apple's standard
    /// SDR rendering, upright. A RAW this device can't decode is reported as unsupported, not exported small.
    private func openRAW(_ url: URL) throws -> CIImage {
        guard let image = CIRAWFilter(imageURL: url)?.outputImage, image.extent.width > 0, image.extent.height > 0 else {
            throw UnderBlueError.unsupported
        }
        return image
    }
    func analyze(_ url: URL) async throws -> WaterAnalysis {
        let source = engine.sdr(try open(url))
        return try await prepare(url: url, source: source).analysis
    }
    func preview(_ url: URL, settings: FilterSettings, original: Bool, maxPixel: CGFloat = 1600) async throws -> CGImage {
        try Task.checkCancellation()
        let source = engine.sdr(try open(url))
        let plan = original ? nil : try await prepare(url: url, source: source).plan
        let ratio = min(1, maxPixel / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        let result = original ? small : processed(small, settings: settings, plan: plan)
        guard let rendered = engine.context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace) else { throw UnderBlueError.unreadable }
        return rendered
    }
    /// Headroom above SDR white. Above 1, the photo can export as HDR. RAW opens as SDR.
    func headroom(_ url: URL) throws -> Float { try open(url).contentHeadroom }

    /// `keepHDR` adds a gain map when the source is HDR. SDR sources always export SDR.
    /// Quality is 1 in both formats. Below it, ImageIO wrote JPEG with half-resolution colour (4:2:0).
    /// In both formats, quality 0.95 to 0.99 barely changed the error (measured 28 Sep 2026).
    /// A JPEG source is already compressed, so each save must add as little loss as possible.
    func export(_ url: URL, settings: FilterSettings, keepHDR: Bool = false,
                format: ExportOptions.PhotoFormat = .jpeg) async throws -> URL {
        try Task.checkCancellation()
        let original = try open(url)
        let source = engine.sdr(original)
        let plan = try await prepare(url: url, source: source).plan
        let image = processed(source, settings: settings, plan: plan)
        // The SDR image in the file is the normal export. The HDR version (PhotoHDR) becomes its gain map.
        var hdr: CIImage?
        if keepHDR, original.contentHeadroom > 1 {
            guard let expanded = photoHDR.reexpand(image, original: original, toneMapped: source) else { throw UnderBlueError.exportFailed }
            hdr = expanded
        }
        let target = try TemporaryFiles.makeURL(extension: format.fileExtension)
        do {
            var options: [CIImageRepresentationOption: Any] = [Self.quality: 1.0]
            if let hdr { options[.hdrImage] = hdr }
            let tagged = image.settingProperties(Self.metadata(from: url))
            switch format {
            case .jpeg:
                try engine.context.writeJPEGRepresentation(of: tagged, to: target, colorSpace: FilterEngine.photoSpace, options: options)
            case .heic:
                try engine.context.writeHEIF10Representation(of: tagged, to: target, colorSpace: FilterEngine.photoSpace, options: options)
            }
            try Task.checkCancellation()
            try Self.check(target, format: format, size: image.extent.size, hdr: hdr != nil)
            return target
        } catch { TemporaryFiles.remove(target); throw error }
    }

    private static let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)

    /// A file reaches the user only if it opens at full size in the chosen format. HEIC must hold 10 bits,
    /// and an HDR export its gain map with headroom above SDR white.
    private static func check(_ url: URL, format: ExportOptions.PhotoFormat, size: CGSize, hdr: Bool) throws {
        guard let file = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(file) == 1,
              CGImageSourceGetType(file) as String? == format.type.identifier,
              let decoded = CGImageSourceCreateImageAtIndex(file, 0, nil),
              decoded.width == Int(size.width.rounded()), decoded.height == Int(size.height.rounded()),
              format == .jpeg || (CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any])?[kCGImagePropertyDepth] as? Int == 10
        else { throw UnderBlueError.invalidOutput }
        guard hdr else { return }
        guard CGImageSourceCopyAuxiliaryDataInfoAtIndex(file, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil,
              let expanded = CIImage(contentsOf: url, options: [.expandToHDR: true]), expanded.contentHeadroom > 1
        else { throw UnderBlueError.invalidOutput }
    }

    /// Orientation is baked into the pixels. Only the capture dates are kept: no stale thumbnails,
    /// dimensions or source gain maps.
    private static func metadata(from url: URL) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = original[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var dates: [CFString: Any] = [:]
            for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] { dates[key] = exif[key] }
            properties[kCGImagePropertyExifDictionary] = dates
        }
        return properties
    }

    #if DEBUG
    /// LLDB/tests can render all four variants without adding temporary production UI.
    func comparisonPreviews(_ url: URL, settings: FilterSettings) async throws -> [PhotoPipelineVariant: CGImage] {
        let source = engine.sdr(try open(url))
        let plan = try await prepare(url: url, source: source).plan
        let ratio = min(1, 1600 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        var result: [PhotoPipelineVariant: CGImage] = [:]
        for variant in PhotoPipelineVariant.allCases {
            let image = processed(small, settings: settings, plan: plan, debugVariant: variant)
            if let rendered = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: FilterEngine.photoSpace) {
                result[variant] = rendered
            }
        }
        return result
    }
    #endif

    /// Drops a photo's cached analysis once it leaves the session.
    func forget(_ url: URL) { prepared[url] = nil }

    private func prepare(url: URL, source: CIImage) async throws -> Prepared {
        if let cached = prepared[url] { return cached }
        let analysis = engine.analyze(source)
        #if DEBUG
        logger.debug("current values(natural): \(ColorCorrection.make(analysis: analysis, preset: .natural).logDescription, privacy: .public)")
        #endif
        if let diagnostics {
            // A real measurement never equals .neutral; it means no usable pixels were found.
            if analysis == .neutral {
                await diagnostics.record(.restorationFallback(.photoNoUsablePixels), operation: .photoRestoration)
            }
            // A missing finishing kernel silently weakens every output, so report it once per processor.
            if !engine.finishingKernelAvailable, !recordedKernelFallback {
                recordedKernelFallback = true
                await diagnostics.record(.restorationFallback(.finishKernel), operation: .photoRestoration)
            }
        }
        recordedRenderFallback = false
        var restorationPlan: RestorationPlan?
        do {
            let depth = try await depthEstimator.estimate(image: source, sourceURL: url)
            try Task.checkCancellation()
            var plan = try waterEstimator.estimate(image: source, depth: depth, legacy: analysis, context: engine.context)
            plan.subjectMask = SubjectMask.estimate(source)
            restorationPlan = plan
            #if DEBUG
            logger.debug("Binf=(\(plan.backscatterInfinity.x),\(plan.backscatterInfinity.y),\(plan.backscatterInfinity.z)) betaD=(\(plan.betaDirect.x),\(plan.betaDirect.y),\(plan.betaDirect.z)) betaB=(\(plan.betaBackscatter.x),\(plan.betaBackscatter.y),\(plan.betaBackscatter.z)) confidence=\(plan.confidence) floorPixels=\(plan.transmissionFloorPixelPercentage)% maxGainPixels=\(plan.maximumGainPixelPercentage)%")
            logger.debug("restored values(natural): \(ColorCorrection.make(analysis: analysis, preset: .natural, plan: plan).logDescription, privacy: .public)")
            #endif
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Depth/model/fitting failures deliberately preserve the shipping UnderBlue result.
            if let diagnostics {
                let failure = (error as? RestorationError).map { Failure.restorationFallback(.photoAnalysis, cause: $0) }
                    ?? .restorationFallback(.photoAnalysis)
                await diagnostics.record(failure, operation: .photoRestoration)
            }
            #if DEBUG
            logger.debug("Depth-aware restoration unavailable; using current UnderBlue correction")
            #endif
        }
        let result = Prepared(analysis: analysis, plan: restorationPlan)
        prepared[url] = result
        return result
    }

    private func processed(_ source: CIImage, settings: FilterSettings, plan: RestorationPlan?,
                           debugVariant: PhotoPipelineVariant? = nil) -> CIImage {
        let current = engine.apply(source, settings: settings)
        #if DEBUG
        let variant = debugVariant ?? PhotoPipelineVariant.selected
        #else
        let variant = PhotoPipelineVariant.combined
        #endif
        if variant == .original { return source }
        if variant == .current { return current }
        guard let plan else { return current }
        do {
            if variant == .restoration {
                return engine.blend(source, try restorationEngine.restore(source, plan: plan), amount: plan.confidence)
            }
            // The one colour entry point shared with video preview and export. Low-confidence fits
            // approach the exact existing UnderBlue output.
            return try restorationEngine.combined(source, plan: plan, settings: settings, filter: engine)
        } catch {
            if !recordedRenderFallback, let diagnostics {
                recordedRenderFallback = true
                Task { await diagnostics.record(.restorationFallback(.photoRender), operation: .photoRestoration) }
            }
            #if DEBUG
            logger.debug("Restoration render failed; using current UnderBlue correction")
            #endif
            return current
        }
    }
}
