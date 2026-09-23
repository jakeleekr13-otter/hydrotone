import CoreImage
import os

struct RestorationFrameSignature: Sendable, Equatable {
    let luminanceHistogram: [Float]
    let meanChroma: SIMD2<Float>
    let depthMedian: Float
    let waterFitConfidence: Float
}

struct RestorationEnvironmentDetector: Sendable {
    private(set) var baseline: RestorationFrameSignature?
    private var candidatePersistence = 0

    mutating func observe(_ signature: RestorationFrameSignature) -> Bool {
        guard let baseline else { self.baseline = signature; return false }
        let histogramDistance = zip(baseline.luminanceHistogram, signature.luminanceHistogram)
            .reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / 2
        let chromaDelta = baseline.meanChroma - signature.meanChroma
        let chromaDistance = sqrt(chromaDelta.x * chromaDelta.x + chromaDelta.y * chromaDelta.y)
        let depthDistance = abs(baseline.depthMedian - signature.depthMedian)
        let fitChange = abs(baseline.waterFitConfidence - signature.waterFitConfidence)
        let evidence = [histogramDistance > 0.34, chromaDistance > 0.13,
                        depthDistance > 0.24, fitChange > 0.38].filter { $0 }.count
        if evidence >= 2 { candidatePersistence += 1 }
        else { candidatePersistence = max(0, candidatePersistence - 1) }
        if candidatePersistence >= 2 {
            self.baseline = signature
            candidatePersistence = 0
            return true
        }
        // Slowly follow ordinary camera movement without treating it as a new environment.
        if evidence == 0 { self.baseline = blend(baseline, signature, amount: 0.08) }
        return false
    }

    mutating func reset(to signature: RestorationFrameSignature? = nil) {
        baseline = signature
        candidatePersistence = 0
    }

    private func blend(_ a: RestorationFrameSignature, _ b: RestorationFrameSignature,
                       amount: Float) -> RestorationFrameSignature {
        RestorationFrameSignature(
            luminanceHistogram: zip(a.luminanceHistogram, b.luminanceHistogram).map { $0 + ($1 - $0) * amount },
            meanChroma: a.meanChroma + (b.meanChroma - a.meanChroma) * amount,
            depthMedian: a.depthMedian + (b.depthMedian - a.depthMedian) * amount,
            waterFitConfidence: a.waterFitConfidence + (b.waterFitConfidence - a.waterFitConfidence) * amount)
    }
}

final class TemporalRestorationSession {
    private let engine = FilterEngine()
    private let waterEstimator = WaterModelEstimator()
    private let depthEstimator: DepthEstimator
    private let builder = ProcessingPolicyBuilder()
    private let device: DeviceCapabilityProfile
    private let source: VideoSourceProfile
    private let preservesHDR: Bool
    private var policy: ProcessingPolicy
    private var detector = RestorationEnvironmentDetector()
    private var currentDepth: NormalizedDepthMap?
    private var targetDepth: NormalizedDepthMap?
    private var backscatterInfinity: SIMD3<Float>?
    private var betaDirect: SIMD3<Float>?
    private var betaBackscatter: SIMD3<Float>?
    private var recoverability = SIMD3<Float>(repeating: 0)
    private var currentConfidence: Float = 0
    private var currentDepthConfidence: Float = 0
    private var currentWaterConfidence: Float = 0
    private var temporalConfidence: Float = 0
    private var limits = RestorationLimits()
    private var floorPercentage: Float = 0
    private var gainPercentage: Float = 0
    private var lastFrameTime: Double?
    private var lastInferenceTime: Double?
    private var nextInferenceTime: Double = 0
    private var nextEnvironmentCheckTime: Double = 0
    private var lastThermalState: RuntimeThermalState
    private var inferenceCount = 0
    #if DEBUG
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "video-restoration")
    #endif

    init(analysis: VideoRestorationAnalysis, preservesHDR: Bool) {
        device = analysis.deviceProfile
        source = analysis.sourceProfile
        policy = analysis.exportPolicy
        self.preservesHDR = preservesHDR
        lastThermalState = RuntimeThermalState(ProcessInfo.processInfo.thermalState)
        depthEstimator = DepthEstimator(computeUnits: analysis.exportPolicy.computePolicy.coreML)
        if let environment = analysis.initialEnvironment {
            backscatterInfinity = environment.backscatterInfinity
            betaDirect = environment.betaDirect
            betaBackscatter = environment.betaBackscatter
            recoverability = environment.channelRecoverability
            currentConfidence = environment.confidence
            currentWaterConfidence = environment.confidence
        }
    }

    func plan(for image: CIImage, at time: Double, runtime: RuntimeSystemState) async -> RestorationPlan? {
        adaptPolicyIfNeeded(runtime)
        advanceDepth(to: time)
        if currentDepth == nil || time + 0.0001 >= nextInferenceTime {
            await infer(image: image, at: time)
            advanceDepth(to: time)
        }
        guard let depth = currentDepth, let infinity = backscatterInfinity,
              let betaDirect, let betaBackscatter else { return nil }
        let elapsed = max(0, time - (lastInferenceTime ?? time))
        let staleConfidence = Float(max(0.5, exp(-elapsed * 0.12)))
        var outputLimits = limits
        if preservesHDR { outputLimits.maximumOutput = 8 }
        return RestorationPlan(
            depth: depth, depthSource: .monocular,
            depthStatistics: statistics(depth.values), backscatterInfinity: infinity,
            betaDirect: betaDirect, betaBackscatter: betaBackscatter,
            confidence: currentConfidence * staleConfidence, limits: outputLimits,
            transmissionFloorPixelPercentage: floorPercentage,
            maximumGainPixelPercentage: gainPercentage,
            depthConfidence: currentDepthConfidence,
            waterFitConfidence: currentWaterConfidence,
            temporalConfidence: temporalConfidence * staleConfidence,
            channelRecoverability: recoverability)
    }

    private func infer(image: CIImage, at time: Double) async {
        let interval = 1 / max(0.5, policy.depthInferencesPerSecond)
        nextInferenceTime = time + interval
        do {
            let analysisImage = engine.sdr(image)
            let depth = try await depthEstimator.monocularDepth(for: analysisImage)
                .resampled(maxDimension: policy.depthMapMaxDimension)
            let legacy = engine.analyze(analysisImage)
            let candidate = try waterEstimator.estimate(image: analysisImage, depth: depth,
                                                         legacy: legacy, context: engine.context)
            let depthDifference = difference(currentDepth, depth.map)
            let newTemporalConfidence = max(0.2, min(1, exp(-depthDifference * 3)))
            let signature = makeSignature(image: analysisImage, plan: candidate)
            let environmentChanged: Bool
            if time + 0.0001 >= nextEnvironmentCheckTime {
                environmentChanged = detector.observe(signature)
                nextEnvironmentCheckTime = time + 1 / max(0.25, policy.environmentChecksPerSecond)
            } else { environmentChanged = false }
            let delta = parameterDistance(candidate)
            let elapsed = max(0.001, time - (lastInferenceTime ?? time - interval))
            var alpha = Float(1 - exp(-elapsed / 1.25)) * max(0.15, candidate.confidence)
            if !environmentChanged, delta > 0.8, candidate.confidence < currentConfidence { alpha = 0 }
            if environmentChanged || backscatterInfinity == nil {
                backscatterInfinity = candidate.backscatterInfinity
                betaDirect = candidate.betaDirect
                betaBackscatter = candidate.betaBackscatter
                recoverability = candidate.channelRecoverability
                currentConfidence = candidate.confidence
                currentWaterConfidence = candidate.waterFitConfidence
                currentDepth = depth.map
                targetDepth = depth.map
                temporalConfidence = candidate.temporalConfidence
                #if DEBUG
                logger.debug("environment-change time=\(time) reset=true")
                #endif
            } else if alpha > 0 {
                backscatterInfinity = mix(backscatterInfinity!, candidate.backscatterInfinity, alpha)
                betaDirect = mix(betaDirect!, candidate.betaDirect, alpha)
                betaBackscatter = mix(betaBackscatter!, candidate.betaBackscatter, alpha)
                recoverability = mix(recoverability, candidate.channelRecoverability, alpha)
                currentConfidence = mix(currentConfidence, candidate.confidence, alpha)
                currentWaterConfidence = mix(currentWaterConfidence, candidate.waterFitConfidence, alpha)
                temporalConfidence = mix(temporalConfidence, newTemporalConfidence, min(1, alpha + 0.1))
                targetDepth = depth.map
            }
            currentDepthConfidence = depth.confidence
            limits = candidate.limits
            floorPercentage = candidate.transmissionFloorPixelPercentage
            gainPercentage = candidate.maximumGainPixelPercentage
            lastInferenceTime = time
            inferenceCount += 1
            #if DEBUG
            let weights = recoverability * min(currentConfidence, currentDepthConfidence,
                                                currentWaterConfidence, temporalConfidence)
            logger.debug("time=\(time) inference=\(self.inferenceCount) depthMS=\(depth.inferenceMilliseconds ?? -1) depthConfidence=\(self.currentDepthConfidence) waterConfidence=\(self.currentWaterConfidence) temporalConfidence=\(self.temporalConfidence) recoverability=(\(self.recoverability.x),\(self.recoverability.y),\(self.recoverability.z)) weights=(\(weights.x),\(weights.y),\(weights.z)) Binf=(\(self.backscatterInfinity?.x ?? 0),\(self.backscatterInfinity?.y ?? 0),\(self.backscatterInfinity?.z ?? 0)) betaD=(\(self.betaDirect?.x ?? 0),\(self.betaDirect?.y ?? 0),\(self.betaDirect?.z ?? 0)) betaB=(\(self.betaBackscatter?.x ?? 0),\(self.betaBackscatter?.y ?? 0),\(self.betaBackscatter?.z ?? 0)) floor=\(self.floorPercentage) maxGain=\(self.gainPercentage)")
            #endif
        } catch is CancellationError {
            return
        } catch {
            currentConfidence *= 0.85
            temporalConfidence *= 0.85
            #if DEBUG
            logger.debug("time=\(time) physical analysis failed; continuing HydroTone fallback")
            #endif
        }
    }

    private func advanceDepth(to time: Double) {
        defer { lastFrameTime = time }
        guard let targetDepth else { return }
        guard let currentDepth, currentDepth.width == targetDepth.width,
              currentDepth.height == targetDepth.height else { self.currentDepth = targetDepth; return }
        let elapsed = max(0, time - (lastFrameTime ?? time))
        let alpha = Float(1 - exp(-elapsed / 0.22))
        guard alpha > 0 else { return }
        let values = zip(currentDepth.values, targetDepth.values).map { min(1, max(0, $0 + ($1 - $0) * alpha)) }
        self.currentDepth = try? NormalizedDepthMap(width: currentDepth.width, height: currentDepth.height, values: values)
    }

    private func adaptPolicyIfNeeded(_ runtime: RuntimeSystemState) {
        guard runtime.thermalState != lastThermalState else { return }
        let next = builder.make(device: device, source: source, runtime: runtime, purpose: .export)
        #if DEBUG
        logger.debug("policy-change thermal=\(runtime.thermalState.rawValue) cadence=\(next.depthInferencesPerSecond) reason=thermal; output unchanged")
        #endif
        policy = next
        lastThermalState = runtime.thermalState
    }

    private func parameterDistance(_ plan: RestorationPlan) -> Float {
        guard let infinity = backscatterInfinity, let direct = betaDirect, let backscatter = betaBackscatter else { return 0 }
        return distance(infinity, plan.backscatterInfinity)
            + distance(direct, plan.betaDirect) * 0.5
            + distance(backscatter, plan.betaBackscatter) * 0.5
    }

    private func difference(_ current: NormalizedDepthMap?, _ next: NormalizedDepthMap) -> Float {
        guard let current, current.width == next.width, current.height == next.height else { return 0 }
        let stride = max(1, current.values.count / 4096)
        var total: Float = 0, count: Float = 0
        for index in Swift.stride(from: 0, to: current.values.count, by: stride) {
            total += abs(current.values[index] - next.values[index]); count += 1
        }
        return count > 0 ? total / count : 0
    }

    private func makeSignature(image: CIImage, plan: RestorationPlan) -> RestorationFrameSignature {
        let size = 48
        let translated = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(size) / image.extent.width,
                                                                  y: CGFloat(size) / image.extent.height))
        var pixels = [Float](repeating: 0, count: size * size * 4)
        engine.context.render(scaled, toBitmap: &pixels, rowBytes: size * 16,
                              bounds: CGRect(x: 0, y: 0, width: size, height: size),
                              format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        var histogram = [Float](repeating: 0, count: 12)
        var chroma = SIMD2<Float>(repeating: 0), count: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = max(0, pixels[index]), g = max(0, pixels[index + 1]), b = max(0, pixels[index + 2])
            let luma = min(0.999, max(0, r * 0.2126 + g * 0.7152 + b * 0.0722))
            histogram[min(11, Int(luma * 12))] += 1
            let sum = max(0.001, r + g + b)
            chroma += SIMD2(r / sum, b / sum); count += 1
        }
        if count > 0 { histogram = histogram.map { $0 / count }; chroma /= count }
        let depthValues = plan.depth.values.sorted()
        return RestorationFrameSignature(luminanceHistogram: histogram, meanChroma: chroma,
                                         depthMedian: depthValues[depthValues.count / 2],
                                         waterFitConfidence: plan.waterFitConfidence)
    }

    private func statistics(_ values: [Float]) -> DepthStatistics {
        let sorted = values.sorted()
        return .init(minimum: sorted.first ?? 0, maximum: sorted.last ?? 0,
                     median: sorted.isEmpty ? 0 : sorted[sorted.count / 2])
    }

    private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let delta = a - b
        return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    }

    private func mix(_ a: Float, _ b: Float, _ amount: Float) -> Float { a + (b - a) * min(1, max(0, amount)) }
    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> { a + (b - a) * min(1, max(0, amount)) }
}
