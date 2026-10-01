import XCTest
import CoreImage
import AVFoundation
@testable import UnderBlue

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

    func testSceneValuesHoldInsideAScene() throws {
        let analysis = try twoScenes(firstEnd: 10, secondStart: 11)
        for time in [-1.0, 0, 5, 10] {
            let moment = try XCTUnwrap(analysis.moment(at: time))
            XCTAssertEqual(moment.amount, 0, "t=\(time)")
            XCTAssertEqual(moment.from.start, 0, "t=\(time)")
        }
        for time in [11.0, 15, 20, 99] {
            let moment = try XCTUnwrap(analysis.moment(at: time))
            XCTAssertEqual(moment.amount, 0, "t=\(time)")
            XCTAssertEqual(moment.from.start, 11, "t=\(time)")
        }
    }

    func testScenesCrossFadeAroundTheMiddleOfTheGap() throws {
        let analysis = try twoScenes(firstEnd: 10, secondStart: 11)
        let middle = try XCTUnwrap(analysis.moment(at: 10.5))
        XCTAssertEqual(middle.amount, 0.5, accuracy: 1e-6)
        let plan = try middle.plan()
        XCTAssertEqual(plan.betaDirect.x, 0.6, accuracy: 1e-5)
        XCTAssertTrue(plan.depth.values.allSatisfy { abs($0 - 0.5) < 1e-5 }, "Constant scene depths mix")
        XCTAssertEqual(plan.temporalConfidence, 0.6, accuracy: 1e-5, "No confidence dip in the middle of a fade")
        XCTAssertEqual(plan.confidence, 0.6, accuracy: 1e-5)
        // Smoothstep: slow at both ends, always rising. At 11.0 the fade has ended and the next scene holds.
        var previous: Float = 0
        for step in 1...19 {
            let amount = try XCTUnwrap(analysis.moment(at: 10 + Double(step) / 20)).amount
            XCTAssertGreaterThanOrEqual(amount, previous)
            previous = amount
        }
        XCTAssertLessThan(try XCTUnwrap(analysis.moment(at: 10.05)).amount, 0.05)
    }

    func testLongGapFadesForOneSecondAtItsMiddle() throws {
        let analysis = try twoScenes(firstEnd: 30, secondStart: 60)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 44.4)).amount, 0)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 44.4)).from.start, 0)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 45)).amount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 45.6)).amount, 0)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 45.6)).from.start, 60)
    }

    /// video2 (1 Oct 2026): scenes of one or two keyframes switched the values against the light, so
    /// the clip flickered at 14 to 18 s. They are skipped; their neighbours fade across the whole gap.
    func testShortScenesAreSkippedAndTheirNeighboursFadeAcrossTheGap() throws {
        let cg = try blackImage()
        let map = try NormalizedDepthMap(width: 2, height: 2, values: .init(repeating: 0.5, count: 4))
        func plan() -> RestorationPlan {
            RestorationPlan(depth: map, depthSource: .monocular, depthStatistics: .init(minimum: 0.5, maximum: 0.5, median: 0.5),
                backscatterInfinity: .init(0.04, 0.08, 0.12), betaDirect: .init(1.2, 0.6, 0.4), betaBackscatter: .init(1.2, 1.6, 1.6),
                confidence: 0.6, limits: .init(), transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0)
        }
        let scenes = [VideoScene(start: 0, end: 10, analysis: .init(redLoss: 0.6), plan: plan(), keyframes: 11),
                      VideoScene(start: 11, end: 12, analysis: .init(redLoss: 0.1), plan: plan(), keyframes: 2),
                      VideoScene(start: 13, end: 13, analysis: .init(redLoss: 0.9), plan: plan(), keyframes: 1),
                      VideoScene(start: 14, end: 30, analysis: .init(redLoss: 0.3), plan: plan(), keyframes: 17)]
        let analysis = VideoRestorationAnalysis(
            legacyAnalysis: .neutral, representativeFrame: cg, representativeTime: 0, scenes: scenes,
            initialEnvironment: nil, deviceProfile: device(.balanced, milliseconds: 50), sourceProfile: source(.medium),
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        // The short scenes never appear; the fade runs from 10 to 14 s and keeps rising.
        var previous: Float = 0
        for step in 1...39 {
            let time = 10 + Double(step) / 10
            let moment = try XCTUnwrap(analysis.moment(at: time))
            XCTAssertEqual(moment.from.start, 0, "t=\(time)")
            XCTAssertEqual(moment.to.start, 14, "t=\(time)")
            XCTAssertGreaterThanOrEqual(moment.amount, previous, "t=\(time)")
            previous = moment.amount
        }
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 10)).amount, 0)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 12)).amount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 14)).from.start, 14)
        XCTAssertEqual(try XCTUnwrap(analysis.moment(at: 20)).from.start, 14)
        // A short scene at the end of the clip is its only measurement there, so it stays.
        let endingShort = VideoRestorationAnalysis(
            legacyAnalysis: .neutral, representativeFrame: cg, representativeTime: 0,
            scenes: scenes + [VideoScene(start: 31, end: 32, analysis: .init(redLoss: 0.5), plan: plan(), keyframes: 2)],
            initialEnvironment: nil, deviceProfile: device(.balanced, milliseconds: 50), sourceProfile: source(.medium),
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        XCTAssertEqual(try XCTUnwrap(endingShort.moment(at: 32)).from.start, 31)
        XCTAssertEqual(try XCTUnwrap(endingShort.moment(at: 12)).to.start, 14)
        // A clip made only of short scenes still uses them.
        let onlyShort = VideoRestorationAnalysis(
            legacyAnalysis: .neutral, representativeFrame: cg, representativeTime: 0, scenes: Array(scenes[1...2]),
            initialEnvironment: nil, deviceProfile: device(.balanced, milliseconds: 50), sourceProfile: source(.medium),
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        XCTAssertEqual(try XCTUnwrap(onlyShort.moment(at: 11)).from.start, 11)
    }

    func testNoScenesMeansNoMoment() throws {
        let cg = try blackImage()
        let analysis = VideoRestorationAnalysis(
            legacyAnalysis: .neutral, representativeFrame: cg, representativeTime: 0, scenes: [],
            initialEnvironment: nil, deviceProfile: device(.balanced, milliseconds: 50), sourceProfile: source(.medium),
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        XCTAssertNil(analysis.moment(at: 3))
    }

    func testFadeMixesEachScenesCorrectionValues() throws {
        let analysis = try twoScenes(firstEnd: 10, secondStart: 11)
        let moment = try XCTUnwrap(analysis.moment(at: 10.5))
        let engine = RestorationEngine()
        let settings = FilterSettings(preset: .natural, intensity: 1)
        var first = settings; first.analysis = moment.from.analysis
        var second = settings; second.analysis = moment.to.analysis
        let a = engine.corrections(settings: first, plan: moment.from.plan)
        let b = engine.corrections(settings: second, plan: moment.to.plan)
        XCTAssertNotEqual(a.restored.midLift, b.restored.midLift, "The two scenes must differ for this test")
        let mixed = moment.corrections(settings: settings, engine: engine)
        XCTAssertEqual(mixed.restored.midLift, (a.restored.midLift + b.restored.midLift) / 2, accuracy: 1e-5)
        XCTAssertEqual(mixed.current.castGains.x, (a.current.castGains.x + b.current.castGains.x) / 2, accuracy: 1e-5)
        XCTAssertEqual(mixed.restored.physicalWeight, (a.restored.physicalWeight + b.restored.physicalWeight) / 2, accuracy: 1e-5)
    }

    func testOneSceneRendersExactlyLikeThePhotoPath() throws {
        let analysis = try twoScenes(firstEnd: 10, secondStart: 11)
        let moment = try XCTUnwrap(analysis.moment(at: 5))
        let engine = FilterEngine(), restoration = RestorationEngine()
        // An 8x8 blue-green ramp, so the tone rules see more than one level.
        var ramp: [UInt8] = []
        for i in 0..<64 {
            let red = UInt8(i / 4), green = UInt8(30 + i * 2), blue = UInt8(60 + i * 2)
            ramp += [red, green, blue, 255]
        }
        let image = CIImage(bitmapData: Data(ramp), bytesPerRow: 32, size: CGSize(width: 8, height: 8),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var photoSettings = FilterSettings(preset: .natural, intensity: 0.8)
        photoSettings.analysis = moment.from.analysis
        let video = try restoration.combined(image, moment: moment, settings: FilterSettings(preset: .natural, intensity: 0.8), filter: engine)
        let photo = try restoration.combined(image, plan: moment.from.plan, settings: photoSettings, filter: engine)
        XCTAssertEqual(try pixels(video, engine), try pixels(photo, engine))
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

    /// The Rec. 709 tag is set on a rebuilt composition. It must keep the filter, so a preview frame
    /// differs from the source frame.
    func testPreviewCompositionStillAppliesTheCorrection() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        let settings = PreviewSettings()
        settings.update(.init(preset: .natural, intensity: 1, analysis: .init(redLoss: 0.6)), comparing: false)
        func frame(_ composition: AVVideoComposition?) async throws -> [UInt8] {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.videoComposition = composition
            generator.maximumSize = CGSize(width: 64, height: 64)
            let image = try await generator.image(at: CMTime(value: 1, timescale: 10)).image
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return pixels
        }
        let source = try await frame(nil)
        let corrected = try await frame(try await VideoPreview().composition(asset: asset, settings: settings))
        func difference(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } / a.count }
        // Control: a composition without the filter differs only by colour conversion.
        let plain = try await frame(AVVideoComposition(configuration: try await .init(for: asset)))
        let filtered = difference(source, corrected), unfiltered = difference(source, plain)
        print("preview difference: filtered \(filtered), unfiltered \(unfiltered)")
        XCTAssertGreaterThan(filtered, unfiltered + 3, "The preview composition lost its correction filter")
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
            representativeTime: 0, scenes: [], initialEnvironment: nil,
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

    /// video3 (1 Oct 2026): the whole scene analysis failed (diagnostic code 6), so the clip got only the
    /// neutral standard correction. A keyframe past the last video frame cannot be read, and an audio
    /// track longer than the video put the last keyframe there. Keyframes now stay inside the video track.
    func testAnalysisSucceedsWhenTheAudioOutlastsTheVideo() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let source = AVURLAsset(url: fixture)
        let composition = AVMutableComposition()
        let half = CMTime(seconds: 0.3, preferredTimescale: 600), full = try await source.load(.duration)
        let videoTracks = try await source.loadTracks(withMediaType: .video), audioTracks = try await source.loadTracks(withMediaType: .audio)
        let video = try XCTUnwrap(videoTracks.first), audio = try XCTUnwrap(audioTracks.first)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: half), of: video, at: .zero)
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: full), of: audio, at: .zero)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-longer-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: url, as: .mov)

        let metadata = try await MediaInspector().inspect(url)
        XCTAssertGreaterThan(metadata.duration, 0.5)                    // the audio sets the asset duration
        XCTAssertEqual(metadata.videoDuration, 0.3, accuracy: 0.05)     // frames end here
        let suite = "UnderBlue.VideoV2.Tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let analyzer = VideoRestorationAnalyzer(profiler: DeviceCapabilityProfiler(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))))
        let analysis = try await analyzer.analyze(url: url, metadata: metadata)
        XCTAssertLessThanOrEqual(analysis.representativeTime, metadata.videoDuration)
        XCTAssertGreaterThan(analysis.legacyAnalysis.midLuminance, 0)   // a real colour analysis, not the neutral default
        XCTAssertNotEqual(analysis.legacyAnalysis, .neutral)
    }

    /// The challenge clip (1 Oct 2026) showed a vignette: on the restored path the shadow and highlight
    /// filter changed the frame's edge band (up to 0.13 OKLab L brighter corners, lavender at the
    /// bottom). A frame's edge must keep the source's edge-to-inner lightness ratio.
    func testRestoredVideoFrameKeepsItsEdges() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let image = CIImage(cgImage: try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image)
        let engine = FilterEngine(), restoration = RestorationEngine()
        let analysis = engine.analyze(image)
        let map = try NormalizedDepthMap(width: 2, height: 2, values: .init(repeating: 0.6, count: 4))
        var plan = RestorationPlan(depth: map, depthSource: .monocular, depthStatistics: .init(minimum: 0.6, maximum: 0.6, median: 0.6),
            backscatterInfinity: .init(0.04, 0.09, 0.17), betaDirect: .init(0.65, 0.23, 0.13), betaBackscatter: .init(0.35, 0.2, 0.42),
            confidence: 0.7, limits: .init(), transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0)
        plan.veilLevel = (analysis.waterColor * ColorCorrection.luma).sum()
        let scene = VideoScene(start: 0, end: 1, analysis: analysis, plan: plan, keyframes: 3)
        let out = try restoration.combined(image, moment: VideoSceneMoment(from: scene, to: scene, amount: 0),
                                           settings: FilterSettings(preset: .natural, intensity: 0.8, analysis: analysis), filter: engine)
        func lightness(_ i: CIImage, _ r: CGRect) -> Float {
            let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: i, kCIInputExtentKey: CIVector(cgRect: r)])!.outputImage!
            var p = [Float](repeating: 0, count: 4)
            engine.context.render(average, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            return (SIMD3(p[0], p[1], p[2]) * ColorCorrection.luma).sum()
        }
        let e = image.extent, band = e.height / 60
        func edgeRatio(_ i: CIImage) -> Float {
            lightness(i, CGRect(x: e.minX, y: e.minY, width: e.width, height: band))
                / lightness(i, CGRect(x: e.minX, y: e.minY + 6 * band, width: e.width, height: band))
        }
        XCTAssertEqual(edgeRatio(out), edgeRatio(image), accuracy: 0.01)
    }

    func testFiveFrameAnalyzerOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Compressed Depth Anything analysis requires a physical Apple device")
        #else
        let suite = "UnderBlue.VideoV2.Tests.\(UUID().uuidString)"
        // UserDefaults is not Sendable: the profiler actor owns its instance, cleanup uses another.
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let metadata = try await MediaInspector().inspect(url)
        let profiler = DeviceCapabilityProfiler(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let analyzer = VideoRestorationAnalyzer(profiler: profiler)
        let started = Date()
        let analysis = try await analyzer.analyze(url: url, metadata: metadata)
        XCTAssertFalse(analysis.scenes.isEmpty, "Video gets at least one scene with a physical plan")
        XCTAssertNotNil(analysis.initialEnvironment)
        XCTAssertFalse(analysis.exportPolicy.useOpticalFlow)
        XCTAssertTrue((2...5).contains(analysis.exportPolicy.depthInferencesPerSecond))
        let representative = CIImage(cgImage: analysis.representativeFrame)
        await profiler.completeBenchmarkIfNeeded(representativeImage: representative)
        let completedProfile = await profiler.profile(representativeImage: representative)
        XCTAssertNotNil(completedProfile.neuralEngineMilliseconds)
        print("Video V2 keyframe analysis: \(Date().timeIntervalSince(started))s; scenes=\(analysis.scenes.count) all=\(completedProfile.allComputeMilliseconds ?? -1)ms neural=\(completedProfile.neuralEngineMilliseconds ?? -1)ms selected=\(completedProfile.preferredComputePolicy.rawValue)")
        #endif
    }

    func testVideoExportRendersASceneTimeline() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_1080_30_audio", withExtension: "mov"))
        let metadata = try await MediaInspector().inspect(url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let representative = try await generator.image(at: .zero).image
        let split = metadata.duration / 2
        let scenes = [
            VideoScene(start: 0, end: split - 0.5, analysis: .init(redLoss: 0.6),
                       plan: try makePlan(depth: 0.3, confidence: 0.7, direct: .init(repeating: 0.2)).sceneLevel()),
            VideoScene(start: split + 0.5, end: metadata.duration, analysis: .init(redLoss: 0.3),
                       plan: try makePlan(depth: 0.7, confidence: 0.7, direct: .init(repeating: 0.8)).sceneLevel())]
        let analysis = VideoRestorationAnalysis(
            legacyAnalysis: .init(redLoss: 0.45), representativeFrame: representative, representativeTime: 0,
            scenes: scenes, initialEnvironment: nil, deviceProfile: device(.conservative, milliseconds: 120),
            sourceProfile: VideoSourceProfile.make(url: url, metadata: metadata),
            previewPolicy: policy(.preview), exportPolicy: policy(.export))
        let result = try await VideoExporter().export(url: url, metadata: metadata,
            settings: .init(preset: .natural, intensity: 0.8, analysis: analysis.legacyAnalysis),
            options: .init(), restorationAnalysis: analysis) { _ in }
        defer { TemporaryFiles.remove(result.url) }
        XCTAssertGreaterThan(result.frames, 0)
        XCTAssertEqual(result.metadata.displaySize, metadata.displaySize)
    }

    private func twoScenes(firstEnd: Double, secondStart: Double) throws -> VideoRestorationAnalysis {
        let first = try makePlan(depth: 0.2, confidence: 0.7, direct: .init(repeating: 0.2)).sceneLevel()
        let second = try makePlan(depth: 0.8, confidence: 0.5, direct: .init(repeating: 1.0)).sceneLevel()
        let blue = WaterAnalysis(redLoss: 0.7, saturation: 0.75, meanRed: 0.08, meanGreen: 0.19, meanBlue: 0.36,
                                 midLuminance: 0.16, waterRed: 0.05, waterGreen: 0.12, waterBlue: 0.25)
        let dark = WaterAnalysis(redLoss: 0.75, saturation: 0.8, meanRed: 0.04, meanGreen: 0.09, meanBlue: 0.19,
                                 midLuminance: 0.08, waterRed: 0.03, waterGreen: 0.07, waterBlue: 0.16)
        return VideoRestorationAnalysis(
            legacyAnalysis: .neutral, representativeFrame: try blackImage(), representativeTime: 5,
            scenes: [VideoScene(start: 0, end: firstEnd, analysis: blue, plan: first),
                     VideoScene(start: secondStart, end: secondStart + 9, analysis: dark, plan: second)],
            initialEnvironment: nil, deviceProfile: device(.balanced, milliseconds: 50),
            sourceProfile: source(.medium), previewPolicy: policy(.preview), exportPolicy: policy(.export))
    }

    private func blackImage() throws -> CGImage {
        try XCTUnwrap(CIContext().createCGImage(
            CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2)),
            from: CGRect(x: 0, y: 0, width: 2, height: 2)))
    }

    private func pixels(_ image: CIImage, _ engine: FilterEngine) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        engine.context.render(image, toBitmap: &bytes, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
                              format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
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
