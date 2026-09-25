import XCTest
import CoreImage
import AVFoundation
@testable import HydroTone

final class VideoRestorationTests: XCTestCase {
    func testPolicyUsesDeviceAndSourceWithoutChangingOutputConfiguration() {
        let high = device(.high, milliseconds: 25)
        let light = source(.light)
        let heavy = source(.heavy)
        let builder = ProcessingPolicyBuilder()
        let runtime = RuntimeSystemState(thermalState: .nominal, observedProcessingFPS: nil)
        let lightPolicy = builder.make(device: high, source: light, runtime: runtime, purpose: .export)
        let heavyPolicy = builder.make(device: high, source: heavy, runtime: runtime, purpose: .export)
        XCTAssertGreaterThan(lightPolicy.depthInferencesPerSecond, heavyPolicy.depthInferencesPerSecond)
        XCTAssertGreaterThan(lightPolicy.depthMapMaxDimension, heavyPolicy.depthMapMaxDimension)

        let requested = ExportOptions(resolution: .source, range: .hdr)
        let adapted = heavyPolicy.adapted(to: .init(thermalState: .serious, observedProcessingFPS: 4))
        XCTAssertLessThan(adapted.depthInferencesPerSecond, heavyPolicy.depthInferencesPerSecond)
        XCTAssertEqual(adapted.depthMapMaxDimension, heavyPolicy.depthMapMaxDimension)
        XCTAssertEqual(requested.resolution, .source)
        XCTAssertEqual(requested.range, .hdr)
    }

    func testRestorationConfidenceIsIndependentOfDevicePerformance() throws {
        let plan = try makePlan(depth: 0.5, confidence: 0.6, recoverability: .init(0.2, 0.8, 1))
        _ = ProcessingPolicyBuilder().make(device: device(.conservative, milliseconds: 120),
                                           source: source(.heavy), runtime: .current, purpose: .export)
        XCTAssertEqual(plan.confidence, 0.6, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveChannelWeights.x, 0.12, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveChannelWeights.y, 0.48, accuracy: 0.0001)
        XCTAssertEqual(plan.effectiveChannelWeights.z, 0.6, accuracy: 0.0001)
    }

    func testIndividualRecoverabilityGatesChannels() {
        let source = SIMD3<Float>(0.12, 0.35, 0.62)
        let result = RestorationMath.inverse(observed: source, depth: 0.8,
            backscatterInfinity: .init(0.04, 0.1, 0.2), betaDirect: .init(1.1, 0.5, 0.25),
            betaBackscatter: .init(0.6, 0.4, 0.3), limits: .init(),
            recoverability: .init(0, 1, 0.5))
        XCTAssertEqual(result.color.x, source.x, accuracy: 0.0001)
        XCTAssertNotEqual(result.color.y, source.y, accuracy: 0.0001)
        XCTAssertLessThan(abs(result.color.z - source.z), abs(result.color.y - source.y) + 0.5)
    }

    func testEnvironmentChangeRequiresPersistentMultipleSignals() {
        var detector = RestorationEnvironmentDetector()
        let baseline = signature(histogramIndex: 2, chroma: .init(0.2, 0.5), depth: 0.4, fit: 0.8)
        let changed = signature(histogramIndex: 9, chroma: .init(0.65, 0.1), depth: 0.8, fit: 0.2)
        XCTAssertFalse(detector.observe(baseline))
        XCTAssertFalse(detector.observe(changed), "One anomalous keyframe must not reset the environment")
        XCTAssertTrue(detector.observe(changed), "A persistent multi-signal change should reset")
    }

    func testSingleSignalMotionDoesNotResetEnvironment() {
        var detector = RestorationEnvironmentDetector()
        let baseline = signature(histogramIndex: 3, chroma: .init(0.3, 0.4), depth: 0.3, fit: 0.8)
        let motionOnly = signature(histogramIndex: 3, chroma: .init(0.3, 0.4), depth: 0.9, fit: 0.8)
        XCTAssertFalse(detector.observe(baseline))
        for _ in 0..<4 { XCTAssertFalse(detector.observe(motionOnly)) }
    }

    func testPreviewInterpolatesParametersButNeverUnrelatedDepthMaps() throws {
        let first = try makePlan(depth: 0, confidence: 0.7, direct: .init(repeating: 0.2))
        let second = try makePlan(depth: 1, confidence: 0.7, direct: .init(repeating: 1.0))
        let cg = try XCTUnwrap(CIContext().createCGImage(
            CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            from: CGRect(x: 0, y: 0, width: 2, height: 2)))
        let analysis = VideoRestorationAnalysis(
            legacyAnalysis: .neutral, representativeFrame: cg, representativeTime: 5,
            samplePlans: [.init(time: 0, plan: first), .init(time: 10, plan: second)],
            initialEnvironment: nil, deviceProfile: device(.balanced, milliseconds: 50),
            sourceProfile: source(.medium),
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        let midpoint = try XCTUnwrap(analysis.previewPlan(at: 5))
        XCTAssertTrue(midpoint.depth.values.allSatisfy { $0 == 1 }, "Depth maps must not be averaged across frames")
        XCTAssertEqual(midpoint.betaDirect.x, 0.6, accuracy: 0.0001)
    }

    func testPreviewGenerationRejectsStaleResults() {
        var generation = PreviewGeneration()
        let a = generation.begin(), b = generation.begin(), c = generation.begin()
        XCTAssertFalse(generation.accepts(a)); XCTAssertFalse(generation.accepts(b)); XCTAssertTrue(generation.accepts(c))
    }

    func testPresetAndIntensityRefreshCreateFreshVideoComposition() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        let settings = PreviewSettings()
        settings.update(.init(preset: .natural, intensity: 0.4), comparing: false)
        let first = try await VideoPreview().composition(asset: asset, settings: settings)
        settings.update(.init(preset: .deep, intensity: 0.9), comparing: false)
        let second = try await VideoPreview().composition(asset: asset, settings: settings)
        XCTAssertFalse(first === second, "A preset revision must invalidate AVPlayer's rendered-frame cache")
    }

    func testDepthMedianMatchesFullSort() throws {
        var generator = SystemRandomNumberGenerator()
        for count in [4, 5, 6, 97, 1_000] {
            let values = (0..<count).map { _ in Float(Int.random(in: 0...20, using: &generator)) / 20 }
            let map = try NormalizedDepthMap(width: 2, height: count / 2, values: Array(values.prefix(2 * (count / 2))))
            XCTAssertEqual(map.median, map.values.sorted()[map.values.count / 2])
        }
    }

    func testSceneLevelPlanKeepsSceneValuesAndFlattensDepth() throws {
        let map = try NormalizedDepthMap(width: 2, height: 2, values: [0.1, 0.9, 0.4, 0.6])
        let plan = RestorationPlan(depth: map, depthSource: .monocular,
            depthStatistics: .init(minimum: 0.1, maximum: 0.9, median: 0.6),
            backscatterInfinity: .init(0.05, 0.12, 0.25), betaDirect: .init(0.7, 0.4, 0.2),
            betaBackscatter: .init(0.5, 0.35, 0.25), confidence: 0.8, limits: .init(),
            transmissionFloorPixelPercentage: 0.1, maximumGainPixelPercentage: 0.2)
        let scene = try plan.sceneLevel()
        XCTAssertEqual(scene.depth.values, [0.6, 0.6, 0.6, 0.6])
        XCTAssertEqual(scene.betaDirect, plan.betaDirect)
        XCTAssertEqual(scene.backscatterInfinity, plan.backscatterInfinity)
        XCTAssertEqual(scene.confidence, plan.confidence)
        XCTAssertEqual(plan.limiting(maximumOutput: 8).limits.maximumOutput, 8)
    }

    func testPreviewCompositionIsTaggedAsRec709() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let composition = try await VideoPreview().composition(asset: AVURLAsset(url: url), settings: PreviewSettings())
        XCTAssertEqual(composition.colorPrimaries, AVVideoColorPrimaries_ITU_R_709_2)
        XCTAssertEqual(composition.colorTransferFunction, AVVideoTransferFunction_ITU_R_709_2)
        XCTAssertEqual(composition.colorYCbCrMatrix, AVVideoYCbCrMatrix_ITU_R_709_2)
    }

    func testVideoExportContinuesWhenPhysicalAnalysisIsUnavailable() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let metadata = try await MediaInspector().inspect(url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let representative = try await generator.image(at: .zero).image
        let sourceProfile = VideoSourceProfile.make(url: url, metadata: metadata)
        let fallbackAnalysis = VideoRestorationAnalysis(
            legacyAnalysis: .init(redLoss: 0.6), representativeFrame: representative,
            representativeTime: 0, samplePlans: [], initialEnvironment: nil,
            deviceProfile: device(.conservative, milliseconds: 120), sourceProfile: sourceProfile,
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        let started = Date()
        let result = try await VideoExporter().export(url: url, metadata: metadata,
            settings: .init(preset: .natural, intensity: 0.8, analysis: fallbackAnalysis.legacyAnalysis),
            options: .init(), restorationAnalysis: fallbackAnalysis) { _ in }
        defer { TemporaryFiles.remove(result.url) }
        XCTAssertGreaterThan(result.frames, 0)
        XCTAssertEqual(result.metadata.audioTrackCount, metadata.audioTrackCount)
        XCTAssertEqual(result.metadata.displaySize, metadata.displaySize)
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        print("Video V2 integration export: \(result.frames) frames in \(elapsed)s (\(Double(result.frames) / elapsed) fps)")
    }

    func testFiveFrameAnalyzerOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Compressed Depth Anything analysis requires a physical Apple device")
        #else
        let suite = "HydroTone.VideoV2.Tests.\(UUID().uuidString)"
        // UserDefaults is not Sendable: the profiler actor owns its instance, cleanup uses another.
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let metadata = try await MediaInspector().inspect(url)
        let profiler = DeviceCapabilityProfiler(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let analyzer = VideoRestorationAnalyzer(profiler: profiler)
        let started = Date()
        let analysis = try await analyzer.analyze(url: url, metadata: metadata)
        XCTAssertEqual(analysis.samplePlans.count, 1, "Video applies one averaged scene plan to every frame")
        XCTAssertNotNil(analysis.initialEnvironment)
        XCTAssertFalse(analysis.exportPolicy.useOpticalFlow)
        XCTAssertTrue((2...5).contains(analysis.exportPolicy.depthInferencesPerSecond))
        let representative = CIImage(cgImage: analysis.representativeFrame)
        await profiler.completeBenchmarkIfNeeded(representativeImage: representative)
        let completedProfile = await profiler.profile(representativeImage: representative)
        XCTAssertNotNil(completedProfile.neuralEngineMilliseconds)
        print("Video V2 five-frame analysis: \(Date().timeIntervalSince(started))s; all=\(completedProfile.allComputeMilliseconds ?? -1)ms neural=\(completedProfile.neuralEngineMilliseconds ?? -1)ms selected=\(completedProfile.preferredComputePolicy.rawValue)")
        #endif
    }

    private func makePlan(depth: Float, confidence: Float,
                          recoverability: SIMD3<Float> = .init(repeating: 1),
                          direct: SIMD3<Float> = .init(0.7, 0.4, 0.2)) throws -> RestorationPlan {
        let map = try NormalizedDepthMap(width: 2, height: 2, values: .init(repeating: depth, count: 4))
        return RestorationPlan(depth: map, depthSource: .monocular,
            depthStatistics: .init(minimum: depth, maximum: depth, median: depth),
            backscatterInfinity: .init(0.05, 0.12, 0.25), betaDirect: direct,
            betaBackscatter: .init(0.5, 0.35, 0.25), confidence: confidence,
            limits: .init(), transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0,
            depthConfidence: confidence, waterFitConfidence: confidence, temporalConfidence: confidence,
            channelRecoverability: recoverability)
    }

    private func signature(histogramIndex: Int, chroma: SIMD2<Float>, depth: Float,
                           fit: Float) -> RestorationFrameSignature {
        var histogram = [Float](repeating: 0, count: 12); histogram[histogramIndex] = 1
        return .init(luminanceHistogram: histogram, meanChroma: chroma,
                     depthMedian: depth, waterFitConfidence: fit)
    }

    private func device(_ performance: DevicePerformanceClass, milliseconds: Double) -> DeviceCapabilityProfile {
        .init(performanceClass: performance, preferredComputePolicy: .all,
              measuredDepthMilliseconds: milliseconds, allComputeMilliseconds: milliseconds,
              neuralEngineMilliseconds: nil, supportsDynamicMetalLibraries: true,
              supportsHardwareHEVCDecode: true, supportsHardwareHEVCEncode: true,
              physicalMemoryBytes: 8_000_000_000, cacheVersion: 1)
    }

    private func source(_ workload: VideoSourceWorkload) -> VideoSourceProfile {
        .init(duration: 30, displaySize: workload == .heavy ? .init(width: 3840, height: 2160) : .init(width: 1920, height: 1080),
              frameRate: workload == .heavy ? 60 : 30, codec: "hvc1", bitDepth: 10,
              dynamicRange: workload == .light ? .sdr : .hlg,
              approximateBitsPerSecond: nil, workload: workload)
    }

    private func policy(_ purpose: ProcessingPurpose) -> ProcessingPolicy {
        .init(purpose: purpose, computePolicy: .all, depthMapMaxDimension: 256,
              depthInferencesPerSecond: 2, environmentChecksPerSecond: 1,
              useOpticalFlow: false, maximumConcurrentAnalysisTasks: 1)
    }
}
