import AVFoundation
import CoreImage
import os

struct TimedRestorationPlan: Sendable, Equatable {
    let time: Double
    let plan: RestorationPlan
}

struct InitialRestorationEnvironment: Sendable, Equatable {
    let backscatterInfinity: SIMD3<Float>
    let betaDirect: SIMD3<Float>
    let betaBackscatter: SIMD3<Float>
    let channelRecoverability: SIMD3<Float>
    let confidence: Float
}

struct VideoRestorationAnalysis: @unchecked Sendable {
    let legacyAnalysis: WaterAnalysis
    let representativeFrame: CGImage
    let representativeTime: Double
    let samplePlans: [TimedRestorationPlan]
    let initialEnvironment: InitialRestorationEnvironment?
    let deviceProfile: DeviceCapabilityProfile
    let sourceProfile: VideoSourceProfile
    let previewPolicy: ProcessingPolicy
    let exportPolicy: ProcessingPolicy

    func previewPlan(at time: Double) -> RestorationPlan? {
        guard let first = samplePlans.first else { return nil }
        guard samplePlans.count > 1 else { return first.plan }
        if time <= first.time { return first.plan }
        if let last = samplePlans.last, time >= last.time { return last.plan }
        guard let upperIndex = samplePlans.firstIndex(where: { $0.time >= time }), upperIndex > 0 else {
            return samplePlans.last?.plan
        }
        let lower = samplePlans[upperIndex - 1], upper = samplePlans[upperIndex]
        let span = max(0.001, upper.time - lower.time)
        let fraction = Float(min(1, max(0, (time - lower.time) / span)))
        let nearest = fraction < 0.5 ? lower.plan : upper.plan
        // Depth maps from unrelated frames are never averaged. Only scene-level values interpolate.
        let temporal = max(0.55, 1 - min(fraction, 1 - fraction) * 0.5)
        return RestorationPlan(
            depth: nearest.depth, depthSource: nearest.depthSource, depthStatistics: nearest.depthStatistics,
            backscatterInfinity: mix(lower.plan.backscatterInfinity, upper.plan.backscatterInfinity, fraction),
            betaDirect: mix(lower.plan.betaDirect, upper.plan.betaDirect, fraction),
            betaBackscatter: mix(lower.plan.betaBackscatter, upper.plan.betaBackscatter, fraction),
            confidence: mix(lower.plan.confidence, upper.plan.confidence, fraction),
            limits: nearest.limits,
            transmissionFloorPixelPercentage: mix(lower.plan.transmissionFloorPixelPercentage,
                                                   upper.plan.transmissionFloorPixelPercentage, fraction),
            maximumGainPixelPercentage: mix(lower.plan.maximumGainPixelPercentage,
                                            upper.plan.maximumGainPixelPercentage, fraction),
            depthConfidence: mix(lower.plan.depthConfidence, upper.plan.depthConfidence, fraction),
            waterFitConfidence: mix(lower.plan.waterFitConfidence, upper.plan.waterFitConfidence, fraction),
            temporalConfidence: temporal,
            channelRecoverability: mix(lower.plan.channelRecoverability, upper.plan.channelRecoverability, fraction))
    }

    private func mix(_ a: Float, _ b: Float, _ amount: Float) -> Float { a + (b - a) * amount }
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> { a + (b - a) * amount }
}

actor VideoRestorationAnalyzer {
    private let engine = FilterEngine()
    private let waterEstimator = WaterModelEstimator()
    private let profiler: DeviceCapabilityProfiler
    private let signposter = OSSignposter(subsystem: "com.hydrotone.app", category: "video-analysis")
    #if DEBUG
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "video-analysis")
    #endif

    init(profiler: DeviceCapabilityProfiler = DeviceCapabilityProfiler()) { self.profiler = profiler }

    func analyze(url: URL, metadata: VideoMetadata) async throws -> VideoRestorationAnalysis {
        let interval = signposter.beginInterval("Initial five-frame analysis")
        defer { signposter.endInterval("Initial five-frame analysis", interval) }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)

        let representativeTime = max(0, metadata.duration * 0.5)
        let representative = try await generator.image(at: CMTime(seconds: representativeTime, preferredTimescale: 600)).image
        let representativeImage = engine.sdr(CIImage(cgImage: representative))
        let device = await profiler.profile(representativeImage: representativeImage)
        let source = VideoSourceProfile.make(url: url, metadata: metadata)
        let runtime = RuntimeSystemState.current
        let builder = ProcessingPolicyBuilder()
        let previewPolicy = builder.make(device: device, source: source, runtime: runtime, purpose: .preview)
        let exportPolicy = builder.make(device: device, source: source, runtime: runtime, purpose: .export)
        let depthEstimator = DepthEstimator(computeUnits: device.preferredComputePolicy.coreML)

        var legacySamples: [WaterAnalysis] = []
        var plans: [TimedRestorationPlan] = []
        for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
            try Task.checkCancellation()
            let requested = max(0, min(metadata.duration, metadata.duration * fraction))
            let cg: CGImage
            if fraction == 0.5 { cg = representative }
            else { cg = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 600)).image }
            let image = engine.sdr(CIImage(cgImage: cg))
            let legacy = engine.analyze(image)
            legacySamples.append(legacy)
            do {
                let depth = try await depthEstimator.monocularDepth(for: image)
                    .resampled(maxDimension: previewPolicy.depthMapMaxDimension)
                let plan = try waterEstimator.estimate(image: image, depth: depth, legacy: legacy, context: engine.context)
                plans.append(TimedRestorationPlan(time: requested, plan: plan))
            } catch is CancellationError { throw CancellationError() }
            catch {
                #if DEBUG
                logger.debug("sample=\(fraction) physical-restoration unavailable; retaining HydroTone fallback")
                #endif
            }
        }
        plans.sort { $0.time < $1.time }
        let environment = aggregate(plans.map(\.plan))
        #if DEBUG
        logger.debug("samples=\(plans.count) workload=\(source.workload.rawValue, privacy: .public) previewDepth=\(previewPolicy.depthMapMaxDimension) exportDepth=\(exportPolicy.depthMapMaxDimension) exportCadence=\(exportPolicy.depthInferencesPerSecond) opticalFlow=\(exportPolicy.useOpticalFlow)")
        #endif
        return VideoRestorationAnalysis(legacyAnalysis: .median(legacySamples), representativeFrame: representative,
                                        representativeTime: representativeTime, samplePlans: plans,
                                        initialEnvironment: environment, deviceProfile: device,
                                        sourceProfile: source, previewPolicy: previewPolicy, exportPolicy: exportPolicy)
    }

    private func aggregate(_ plans: [RestorationPlan]) -> InitialRestorationEnvironment? {
        let accepted = plans.filter { $0.confidence >= 0.08 }
        guard !accepted.isEmpty else { return nil }
        func scalar(_ key: (RestorationPlan) -> Float) -> Float {
            weightedMedian(accepted.map { (key($0), max(0.001, $0.confidence)) })
        }
        func vector(_ key: (RestorationPlan) -> SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(weightedMedian(accepted.map { (key($0).x, max(0.001, $0.confidence)) }),
                  weightedMedian(accepted.map { (key($0).y, max(0.001, $0.confidence)) }),
                  weightedMedian(accepted.map { (key($0).z, max(0.001, $0.confidence)) }))
        }
        return InitialRestorationEnvironment(backscatterInfinity: vector(\.backscatterInfinity),
                                             betaDirect: vector(\.betaDirect),
                                             betaBackscatter: vector(\.betaBackscatter),
                                             channelRecoverability: vector(\.channelRecoverability),
                                             confidence: scalar(\.confidence))
    }

    private func weightedMedian(_ input: [(Float, Float)]) -> Float {
        let values = input.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > 0 }.sorted { $0.0 < $1.0 }
        guard !values.isEmpty else { return 0 }
        let half = values.reduce(Float(0)) { $0 + $1.1 } / 2
        var accumulated: Float = 0
        for value in values {
            accumulated += value.1
            if accumulated >= half { return value.0 }
        }
        return values.last!.0
    }
}
