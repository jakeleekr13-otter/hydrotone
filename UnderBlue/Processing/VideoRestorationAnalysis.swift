import AVFoundation
import CoreImage
import os

/// One stretch of video that shows the same scene. Every frame from `start` to `end` (the scene's
/// first and last keyframe) gets the same water analysis and scene-level plan, so the look holds
/// still while the scene does.
struct VideoScene: Sendable, Equatable {
    let start: Double
    let end: Double
    let analysis: WaterAnalysis
    let plan: RestorationPlan

    func limiting(maximumOutput: Float) -> VideoScene {
        VideoScene(start: start, end: end, analysis: analysis, plan: plan.limiting(maximumOutput: maximumOutput))
    }
}

/// The values for one frame: scene `from`, moving to scene `to` by `amount` (0 is only `from`).
struct VideoSceneMoment: Sendable, Equatable {
    let from: VideoScene
    let to: VideoScene
    let amount: Float

    /// The two scene plans mixed. Scene plans carry one constant depth, so mixing the depth is safe.
    func plan() throws -> RestorationPlan {
        if amount <= 0 { return from.plan }
        if amount >= 1 { return to.plan }
        return try from.plan.mixed(with: to.plan, amount: amount)
    }

    /// The correction values for the user's current settings. Each scene gets its own make() result,
    /// then the results mix. So every value moves on a straight line between the two scenes,
    /// whatever make() does inside.
    func corrections(settings: FilterSettings, engine: RestorationEngine) -> (current: ColorCorrection, restored: ColorCorrection) {
        var first = settings
        first.analysis = from.analysis
        let a = engine.corrections(settings: first, plan: from.plan)
        guard amount > 0 else { return a }
        var second = settings
        second.analysis = to.analysis
        let b = engine.corrections(settings: second, plan: to.plan)
        guard amount < 1 else { return b }
        return (a.current.mixed(with: b.current, amount: amount), a.restored.mixed(with: b.restored, amount: amount))
    }

    func limiting(maximumOutput: Float) -> VideoSceneMoment {
        VideoSceneMoment(from: from.limiting(maximumOutput: maximumOutput),
                         to: to.limiting(maximumOutput: maximumOutput), amount: amount)
    }
}

struct InitialRestorationEnvironment: Sendable, Equatable {
    let backscatterInfinity: SIMD3<Float>
    let betaDirect: SIMD3<Float>
    let betaBackscatter: SIMD3<Float>
    let channelRecoverability: SIMD3<Float>
    let confidence: Float
}

struct VideoRestorationAnalysis: Sendable {
    /// The whole clip's mean analysis. The editor keeps it in its settings; rendering uses the scenes.
    let legacyAnalysis: WaterAnalysis
    let representativeFrame: CGImage
    let representativeTime: Double
    /// In time order. Empty when no keyframe gave a physical plan; video then uses the legacy correction.
    let scenes: [VideoScene]
    let initialEnvironment: InitialRestorationEnvironment?
    let deviceProfile: DeviceCapabilityProfile
    let sourceProfile: VideoSourceProfile
    let previewPolicy: ProcessingPolicy
    let exportPolicy: ProcessingPolicy

    /// The longest cross-fade between two scenes, in seconds. The change happens somewhere between
    /// two keyframes, so the fade is centred on the middle of that gap.
    static let sceneFade: Double = 1

    /// The scene values for one frame. Preview and export both use this, so they match.
    func moment(at time: Double) -> VideoSceneMoment? {
        guard var current = scenes.first else { return nil }
        for next in scenes.dropFirst() {
            let middle = (current.end + next.start) / 2
            let half = min(Self.sceneFade, next.start - current.end) / 2
            if time < middle + half {
                guard half > 0, time > middle - half else { return VideoSceneMoment(from: current, to: current, amount: 0) }
                // Smoothstep: the fade starts and ends without a jolt.
                let x = Float((time - (middle - half)) / (2 * half))
                return VideoSceneMoment(from: current, to: next, amount: x * x * (3 - 2 * x))
            }
            current = next
        }
        return VideoSceneMoment(from: current, to: current, amount: 0)
    }
}

/// Splits keyframes into scenes. A new scene starts where the mean colour moves more than
/// `threshold` (OKLab distance) from the running scene's mean, and the next keyframe is that far
/// too. So one odd keyframe never starts a scene.
/// 0.04 is twice the largest drift of a steady 20 s stretch of a real dive clip (28 Sep 2026). On
/// that clip it splits where the camera turns to the sunlit surface and where it turns to deep water.
enum VideoSceneSplitter {
    static let threshold: Float = 0.04

    /// The index of each scene's first keyframe, in order. Starts with 0 when there is a keyframe.
    static func sceneStarts(_ samples: [WaterAnalysis], threshold: Float = threshold) -> [Int] {
        guard !samples.isEmpty else { return [] }
        let colors = samples.map { sample -> SIMD3<Float> in
            let c = sample.meanColor
            return ColorCorrection.oklab(c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : .zero)
        }
        var starts = [0], sum = colors[0], count: Float = 1
        for index in colors.indices.dropFirst() {
            let center = sum / count
            func far(_ i: Int) -> Bool {
                guard i < colors.count else { return false }
                let d = colors[i] - center
                return (d * d).sum().squareRoot() > threshold
            }
            if far(index) && far(index + 1) {
                starts.append(index)
                sum = colors[index]; count = 1
            } else {
                sum += colors[index]; count += 1
            }
        }
        return starts
    }
}

actor VideoRestorationAnalyzer {
    /// Keyframe spacing in seconds on ordinary clips. Short clips still get `minimumKeyframes` and long
    /// clips at most `maximumKeyframes`, so a one-hour clip takes a keyframe every 30 s.
    static let keyframeSpacing: Double = 1
    static let minimumKeyframes = 10
    static let maximumKeyframes = 120
    /// Depth and the water fit are the slow part. Each scene fits at most this many of its keyframes,
    /// evenly spread, so a steady clip fits as many as the old 10-sample analysis did.
    static let maximumFitsPerScene = 10

    /// Keyframe times from the first frame to 0.1 s before the end, evenly spaced.
    static func keyframeTimes(duration: Double) -> [Double] {
        let last = max(0, duration - 0.1)
        let count = min(maximumKeyframes, max(minimumKeyframes, Int(last / keyframeSpacing) + 1))
        guard last > 0, count > 1 else { return [0] }
        return (0..<count).map { last * Double($0) / Double(count - 1) }
    }

    /// At most `count` indices of `range`, evenly spread, the first and the last included.
    static func spread(_ range: Range<Int>, count: Int) -> [Int] {
        guard count > 1, range.count > count else { return Array(range.prefix(max(1, count))) }
        return (0..<count).map { range.lowerBound + Int((Double($0) * Double(range.count - 1) / Double(count - 1)).rounded()) }
    }

    private let engine = FilterEngine()
    private let waterEstimator = WaterModelEstimator()
    private let profiler: DeviceCapabilityProfiler
    private let diagnostics: DiagnosticRecorder?
    private let signposter = OSSignposter(subsystem: "com.underblue.app", category: "video-analysis")
    #if DEBUG
    private let logger = Logger(subsystem: "com.underblue.app", category: "video-analysis")
    #endif

    init(profiler: DeviceCapabilityProfiler = DeviceCapabilityProfiler(),
         diagnostics: DiagnosticRecorder? = nil) {
        self.profiler = profiler
        self.diagnostics = diagnostics
    }

    func analyze(url: URL, metadata: VideoMetadata) async throws -> VideoRestorationAnalysis {
        let interval = signposter.beginInterval("Keyframe analysis")
        defer { signposter.endInterval("Keyframe analysis", interval) }
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

        // Video rule: a keyframe about every second. Keyframes that show the same scene form one scene
        // (VideoSceneSplitter). A scene averages its keyframes, drops odd ones, and its values hold for
        // the whole scene. Between two scenes the values cross-fade (VideoRestorationAnalysis.moment).
        let times = Self.keyframeTimes(duration: metadata.duration)
        var samples: [WaterAnalysis] = []
        for time in times {
            try Task.checkCancellation()
            let cg = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            samples.append(engine.analyze(engine.sdr(CIImage(cgImage: cg))))
        }
        let starts = VideoSceneSplitter.sceneStarts(samples)
        let ranges = zip(starts, starts.dropFirst() + [samples.count]).map { $0..<$1 }

        var plans: [Int: RestorationPlan] = [:]
        var restorationFailures = 0
        for range in ranges {
            for index in Self.spread(range, count: Self.maximumFitsPerScene) {
                try Task.checkCancellation()
                let cg = try await generator.image(at: CMTime(seconds: times[index], preferredTimescale: 600)).image
                let image = engine.sdr(CIImage(cgImage: cg))
                do {
                    let depth = try await depthEstimator.monocularDepth(for: image)
                        .resampled(maxDimension: previewPolicy.depthMapMaxDimension)
                    plans[index] = try waterEstimator.estimate(image: image, depth: depth, legacy: samples[index],
                                                               context: engine.context)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    restorationFailures += 1
                    #if DEBUG
                    logger.debug("keyframe=\(times[index]) physical-restoration unavailable; retaining UnderBlue fallback")
                    #endif
                }
            }
        }
        if restorationFailures > 0, let diagnostics {
            await diagnostics.record(.restorationFallback(.videoInitialAnalysis),
                                     operation: .videoRestoration,
                                     occurrences: restorationFailures)
        }

        // sceneLevel() shrinks the constant depth map to 2x2, so each frame uploads 16 bytes, not a full map.
        // Only kept keyframes enter a plan: rejected ones must not re-enter the physical correction.
        func scenePlan(_ kept: [Int]) -> RestorationPlan? {
            let chosen = kept.compactMap { plans[$0] }
            return try? RestorationPlan.sceneAverage(chosen, keeping: Array(chosen.indices)).sceneLevel()
        }
        let clipKept = WaterAnalysis.sceneInliers(samples)
        var sceneValues: [(range: Range<Int>, analysis: WaterAnalysis, plan: RestorationPlan?)] = []
        for range in ranges {
            let members = Array(range)
            let kept = WaterAnalysis.sceneInliers(members.map { samples[$0] }).map { members[$0] }
            sceneValues.append((range, WaterAnalysis.sceneMean(samples, keeping: kept), scenePlan(kept)))
        }
        // A scene whose fits all failed borrows the whole clip's plan. If every fit failed, no scene
        // has a plan and video keeps only the legacy correction.
        var scenes: [VideoScene] = []
        if let fallback = scenePlan(clipKept) ?? sceneValues.lazy.compactMap({ $0.plan }).first {
            scenes = sceneValues.map {
                VideoScene(start: times[$0.range.lowerBound], end: times[$0.range.upperBound - 1],
                           analysis: $0.analysis, plan: $0.plan ?? fallback)
            }
        }
        let environment = aggregate(clipKept.compactMap { plans[$0] })
        #if DEBUG
        logger.debug("keyframes=\(times.count) scenes=\(starts.map { times[$0] }) fits=\(plans.count) failures=\(restorationFailures) workload=\(source.workload.rawValue, privacy: .public) previewDepth=\(previewPolicy.depthMapMaxDimension)")
        #endif
        Task.detached(priority: .utility) {
            await self.profiler.completeBenchmarkIfNeeded(representativeImage: representativeImage)
        }
        return VideoRestorationAnalysis(legacyAnalysis: .sceneMean(samples, keeping: clipKept),
                                        representativeFrame: representative, representativeTime: representativeTime,
                                        scenes: scenes, initialEnvironment: environment, deviceProfile: device,
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

extension RestorationEngine {
    /// combined() for one video frame. HDR output keeps its highlight headroom (maximum output 8).
    func combined(_ image: CIImage, moment: VideoSceneMoment, settings: FilterSettings,
                  filter: FilterEngine, preservesHDR: Bool = false) throws -> CIImage {
        let moment = preservesHDR ? moment.limiting(maximumOutput: 8) : moment
        return try combined(image, plan: moment.plan(), values: moment.corrections(settings: settings, engine: self),
                            settings: settings, filter: filter)
    }
}

extension ColorCorrection {
    /// Every stored value, for mixing two scenes. A new stored value must be added here, or a scene
    /// change jumps in that value at the end of the fade. A test counts them against the struct.
    static var mixedScalars: [WritableKeyPath<Self, Float>] {
        [\.redRebuild, \.redGateLow, \.redGateHigh, \.subjectRed, \.waterRedness, \.waterSaturation, \.waterChroma,
         \.waterType, \.redCeiling, \.violetGuard, \.midLift, \.toneCurve, \.tonePivot, \.brightness, \.contrast,
         \.saturation, \.shadowLift, \.highlightAmount, \.clarity, \.clarityRadius, \.definition, \.definitionRadius,
         \.detail, \.detailFloor, \.detailRadius, \.warmth, \.vibrance, \.physicalWeight]
    }
    static var mixedVectors: [WritableKeyPath<Self, SIMD3<Float>>] {
        [\.castGains, \.waterTone, \.subjectTone, \.neutralGains, \.waterLit]
    }

    func mixed(with other: Self, amount: Float) -> Self {
        if amount <= 0 { return self }
        if amount >= 1 { return other }
        var v = self
        for key in Self.mixedScalars { v[keyPath: key] += (other[keyPath: key] - self[keyPath: key]) * amount }
        for key in Self.mixedVectors { v[keyPath: key] += (other[keyPath: key] - self[keyPath: key]) * amount }
        return v
    }
}

extension RestorationPlan {
    /// Mixes two scene-level plans. Both carry one constant depth, so their depth maps mix too; maps of
    /// different sizes keep the nearer plan's map. Confidence mixes without a dip in the middle.
    func mixed(with other: RestorationPlan, amount: Float) throws -> RestorationPlan {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * amount }
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * amount }
        let nearest = amount < 0.5 ? self : other
        let mixedDepth = self.depth.width == other.depth.width && self.depth.height == other.depth.height
            ? try NormalizedDepthMap(width: self.depth.width, height: self.depth.height,
                                     values: zip(self.depth.values, other.depth.values).map { mix($0, $1) })
            : nearest.depth
        let mixedLimits = RestorationLimits(transmissionFloor: mix(self.limits.transmissionFloor, other.limits.transmissionFloor),
                                       maximumGain: mix(self.limits.maximumGain, other.limits.maximumGain),
                                       highlightStart: mix(self.limits.highlightStart, other.limits.highlightStart),
                                       highlightEnd: mix(self.limits.highlightEnd, other.limits.highlightEnd),
                                       maximumOutput: mix(self.limits.maximumOutput, other.limits.maximumOutput))
        return RestorationPlan(
            depth: mixedDepth, depthSource: nearest.depthSource,
            depthStatistics: DepthStatistics(minimum: mix(depthStatistics.minimum, other.depthStatistics.minimum),
                                             maximum: mix(depthStatistics.maximum, other.depthStatistics.maximum),
                                             median: mix(depthStatistics.median, other.depthStatistics.median)),
            backscatterInfinity: mix(backscatterInfinity, other.backscatterInfinity),
            betaDirect: mix(betaDirect, other.betaDirect),
            betaBackscatter: mix(betaBackscatter, other.betaBackscatter),
            confidence: mix(confidence, other.confidence),
            limits: mixedLimits,
            transmissionFloorPixelPercentage: mix(transmissionFloorPixelPercentage, other.transmissionFloorPixelPercentage),
            maximumGainPixelPercentage: mix(maximumGainPixelPercentage, other.maximumGainPixelPercentage),
            depthConfidence: mix(depthConfidence, other.depthConfidence),
            waterFitConfidence: mix(waterFitConfidence, other.waterFitConfidence),
            temporalConfidence: mix(temporalConfidence, other.temporalConfidence),
            channelRecoverability: mix(channelRecoverability, other.channelRecoverability))
    }
}
