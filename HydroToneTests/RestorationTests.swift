import XCTest
import CoreImage
@testable import HydroTone

final class RestorationTests: XCTestCase {
    private let parameters = (
        infinity: SIMD3<Float>(0.08, 0.18, 0.32),
        betaDirect: SIMD3<Float>(0.9, 0.45, 0.25),
        betaBackscatter: SIMD3<Float>(0.55, 0.42, 0.31)
    )

    func testImageFormationForwardInverseConsistency() {
        let clear = SIMD3<Float>(0.24, 0.52, 0.68)
        let observed = RestorationMath.forward(clear: clear, depth: 0.55,
            backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
            betaBackscatter: parameters.betaBackscatter)
        let limits = RestorationLimits(transmissionFloor: 0.01, maximumGain: .init(repeating: 10),
                                       highlightStart: 10, highlightEnd: 11, maximumOutput: 4)
        let restored = RestorationMath.inverse(observed: observed, depth: 0.55,
            backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
            betaBackscatter: parameters.betaBackscatter, limits: limits)
        assertEqual(restored.color, clear, accuracy: 0.0001)
        XCTAssertFalse(restored.hitTransmissionFloor)
        XCTAssertFalse(restored.hitMaximumGain)
    }

    func testZeroAndNearZeroDepthRemainStable() {
        let source = SIMD3<Float>(0.2, 0.4, 0.7)
        for depth: Float in [0, 0.000001] {
            let restored = RestorationMath.inverse(observed: source, depth: depth,
                backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
                betaBackscatter: parameters.betaBackscatter, limits: .init())
            assertEqual(restored.color, source, accuracy: 0.00001)
        }
    }

    func testExtremeAttenuationUsesTransmissionFloorAndStaysFinite() {
        let limits = RestorationLimits(transmissionFloor: 0.3, maximumGain: .init(repeating: 10),
                                       highlightStart: 10, highlightEnd: 11, maximumOutput: 2)
        let result = RestorationMath.inverse(observed: .init(repeating: 0.2), depth: 1,
            backscatterInfinity: .zero, betaDirect: .init(repeating: 20),
            betaBackscatter: .init(repeating: 3), limits: limits)
        XCTAssertTrue(result.hitTransmissionFloor)
        XCTAssertTrue(result.color.x.isFinite && result.color.y.isFinite && result.color.z.isFinite)
        XCTAssertEqual(result.color.x, 0.2 / 0.3, accuracy: 0.0001)
    }

    func testMaximumChannelGainIsEnforced() {
        let limits = RestorationLimits(transmissionFloor: 0.01, maximumGain: .init(1.2, 1.3, 1.4),
                                       highlightStart: 10, highlightEnd: 11, maximumOutput: 2)
        let result = RestorationMath.inverse(observed: .init(repeating: 0.1), depth: 1,
            backscatterInfinity: .zero, betaDirect: .init(repeating: 5),
            betaBackscatter: .init(repeating: 1), limits: limits)
        XCTAssertTrue(result.hitMaximumGain)
        XCTAssertEqual(result.color.x, 0.12, accuracy: 0.0001)
        XCTAssertEqual(result.color.y, 0.13, accuracy: 0.0001)
        XCTAssertEqual(result.color.z, 0.14, accuracy: 0.0001)
    }

    func testNaNAndInfinityAreSanitized() {
        let result = RestorationMath.inverse(observed: .init(.nan, .infinity, 0.2), depth: .nan,
            backscatterInfinity: .init(.nan, 0.2, .infinity), betaDirect: .init(.infinity, .nan, 0.2),
            betaBackscatter: .init(.nan, .infinity, 0.2), limits: .init())
        XCTAssertTrue(result.color.x.isFinite && result.color.y.isFinite && result.color.z.isFinite)
        XCTAssertGreaterThanOrEqual(result.color.min(), 0)
    }

    func testConfidenceFallbackAndDeterminism() {
        let current = SIMD3<Float>(0.1, 0.3, 0.6), restored = SIMD3<Float>(0.7, 0.5, 0.2)
        XCTAssertEqual(RestorationMath.confidenceBlend(current: current, restored: restored, confidence: 0), current)
        XCTAssertEqual(RestorationMath.confidenceBlend(current: current, restored: restored, confidence: .nan), current)
        let first = RestorationMath.confidenceBlend(current: current, restored: restored, confidence: 0.35)
        let second = RestorationMath.confidenceBlend(current: current, restored: restored, confidence: 0.35)
        XCTAssertEqual(first, second)
    }

    func testBundledDepthModelProducesCompactFiniteDepth() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Depth Anything's compressed MPSGraph backend requires a physical Apple device")
        #else
        let foreground = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.08))
            .cropped(to: CGRect(x: 70, y: 45, width: 180, height: 130))
        let background = CIImage(color: CIColor(red: 0.05, green: 0.42, blue: 0.65))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 220))
        let image = foreground.composited(over: background)
        let estimate = try await DepthEstimator().monocularDepth(for: image)
        XCTAssertEqual(estimate.map.width, 518)
        XCTAssertEqual(estimate.map.height, 392)
        XCTAssertEqual(estimate.map.values.count, 518 * 392)
        XCTAssertTrue(estimate.map.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertNotNil(estimate.inferenceMilliseconds)
        print("Depth Anything physical inference: \(estimate.inferenceMilliseconds ?? -1) ms")
        #endif
    }

    // MARK: Correction values and the finishing colour kernel

    /// Only the colour-kernel values; every later finishing stage is neutral.
    private func colorOnly(_ edit: (inout ColorCorrection) -> Void) -> ColorCorrection {
        var values = ColorCorrection.identity
        values.castGains = .init(1.0001, 1, 1) // not identity, so finishing runs
        edit(&values)
        return values
    }

    func testMidLiftForwardInverse() {
        // midLift(from:to:) is the inverse of the kernel's lift on a grey pixel.
        for (from, to): (Float, Float) in [(0.05, 0.08), (0.12, 0.18), (0.2, 0.22)] {
            let lift = ColorCorrection.midLift(from: from, to: to)
            XCTAssertGreaterThan(lift, 0)
            let values = colorOnly { $0.castGains = .init(repeating: 1); $0.midLift = lift }
            let out = FinishingMath.color(.init(repeating: from), correction: values)
            assertEqual(out, .init(repeating: to), accuracy: 0.0005)
        }
        XCTAssertEqual(ColorCorrection.midLift(from: 0.2, to: 0.1), 0)
        XCTAssertLessThanOrEqual(ColorCorrection.midLift(from: 0.0001, to: 0.9), 0.9)
    }

    func testLiftAndCurveKeepBlackWhiteAndOrder() {
        let values = colorOnly { $0.castGains = .init(repeating: 1); $0.midLift = 0.9; $0.toneCurve = 0.3; $0.tonePivot = 0.3 }
        XCTAssertEqual(FinishingMath.color(.zero, correction: values), .zero)
        XCTAssertEqual(FinishingMath.color(.init(repeating: 1), correction: values), .init(repeating: 1))
        var previous: Float = 0
        for step in 1...99 {
            let out = FinishingMath.color(.init(repeating: Float(step) / 100), correction: values)
            XCTAssertGreaterThanOrEqual(out.y, previous)
            XCTAssertLessThanOrEqual(out.max(), 1)
            previous = out.y
        }
    }

    func testFinishingNeverRaisesHDRPeaks() {
        let values = colorOnly { $0.midLift = 0.8; $0.toneCurve = 0.3 }
        let source = SIMD3<Float>(0.05, 0.3, 1.6) // luminance below one, so the tone step runs
        let out = FinishingMath.color(source, correction: values)
        XCTAssertLessThanOrEqual(out.max(), source.max() * values.castGains.max() + 1e-5)
        XCTAssertTrue(out.x.isFinite && out.y.isFinite && out.z.isFinite)
    }

    func testBlueWaterGetsNoRedRebuild() {
        let values = colorOnly { $0.castGains = .init(repeating: 1); $0.redRebuild = 0.4; $0.subjectRed = 0.3 }
        let blueWater = SIMD3<Float>(0.05, 0.2, 0.5)  // green/blue 0.4 is below the gate
        XCTAssertEqual(FinishingMath.color(blueWater, correction: values).x, blueWater.x, accuracy: 1e-6)
        let cyanSubject = SIMD3<Float>(0.2, 0.4, 0.45) // green/blue near one, redder than the water
        XCTAssertGreaterThan(FinishingMath.color(cyanSubject, correction: values).x, cyanSubject.x + 0.05)
    }

    func testFinishingKernelMatchesCPUMirror() {
        let engine = FilterEngine()
        let values = colorOnly { $0.castGains = .init(1.3, 0.85, 1.2); $0.redRebuild = 0.25; $0.subjectRed = 0.4
            $0.midLift = 0.5; $0.toneCurve = 0.25; $0.tonePivot = 0.42 }
        for color: SIMD3<Float> in [.init(0.05, 0.3, 0.35), .init(0.3, 0.25, 0.2), .init(0.02, 0.5, 0.3), .init(2.5, 3, 4)] {
            let image = CIImage(color: CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                                               colorSpace: FilterEngine.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            var pixel = [Float](repeating: 0, count: 4)
            engine.context.render(engine.finishing(image, correction: values), toBitmap: &pixel, rowBytes: 16,
                                  bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            let expected = FinishingMath.color(color, correction: values)
            // The working format is half float, so the tolerance grows with the value.
            assertEqual(SIMD3(pixel[0], pixel[1], pixel[2]), expected, accuracy: 0.004 * max(1, expected.max()))
        }
    }

    func testCorrectionValuesAreDeterministicAndScoped() throws {
        let analysis = WaterAnalysis(redLoss: 0.6, cyanDominance: 0.6, exposure: 0.02, contrast: 0.2, saturation: 0.5,
                                     meanRed: 0.08, meanGreen: 0.3, meanBlue: 0.25, midLuminance: 0.15)
        XCTAssertEqual(ColorCorrection.make(analysis: analysis, preset: .original), .identity)
        let current = ColorCorrection.make(analysis: analysis, preset: .natural)
        XCTAssertEqual(current, ColorCorrection.make(analysis: analysis, preset: .natural))
        XCTAssertEqual(current.physicalWeight, 0)
        XCTAssertEqual(current.midLift, 0)
        // Green water: green gain below blue gain moves the water toward blue.
        XCTAssertLessThan(current.castGains.y, current.castGains.z)
        let plan = try makePlan(depth: 0.6, confidence: 0.55)
        let restored = ColorCorrection.make(analysis: analysis, preset: .natural, plan: plan)
        XCTAssertEqual(restored.physicalWeight, plan.confidence, accuracy: 1e-6)
        XCTAssertGreaterThan(restored.midLift, 0)      // the restored image lost veil light
        XCTAssertLessThanOrEqual(restored.midLift, 0.9)
        var bright = analysis; bright.midLuminance = 0.4
        XCTAssertEqual(ColorCorrection.make(analysis: bright, preset: .natural, plan: plan).midLift, 0) // above the ceiling
        var broken = analysis; broken.meanGreen = .nan; broken.contrast = .infinity
        let safe = ColorCorrection.make(analysis: broken, preset: .natural, plan: plan)
        for value in [safe.castGains.x, safe.castGains.y, safe.castGains.z, safe.midLift, safe.toneCurve, safe.contrast] {
            XCTAssertTrue(value.isFinite)
        }
    }

    // MARK: Scene averaging with outlier removal

    private func sample(_ offset: Float) -> WaterAnalysis {
        WaterAnalysis(redLoss: 0.5 + offset, cyanDominance: 0.5 + offset, exposure: 0.02, contrast: 0.2 + offset,
                      saturation: 0.4, meanRed: 0.1, meanGreen: 0.3 + offset, meanBlue: 0.35, midLuminance: 0.16 + offset)
    }

    func testWaterAnalysisFieldListCoversEveryStoredValue() {
        XCTAssertEqual(WaterAnalysis.fields.count, Mirror(reflecting: WaterAnalysis()).children.count)
    }

    func testSceneInliersDropOneOddSample() {
        var samples = (0..<9).map { sample(Float($0) * 0.004) }
        // An above-water frame: bright, no red loss, low cyan, high contrast.
        samples.insert(WaterAnalysis(redLoss: 0, cyanDominance: 0, exposure: 0, contrast: 0.7, saturation: 0.2,
                                     meanRed: 0.6, meanGreen: 0.6, meanBlue: 0.65, midLuminance: 0.55), at: 4)
        let kept = WaterAnalysis.sceneInliers(samples)
        XCTAssertEqual(kept, [0, 1, 2, 3, 5, 6, 7, 8, 9])
        let mean = WaterAnalysis.sceneMean(samples, keeping: kept)
        let similar = samples.enumerated().filter { $0.offset != 4 }.map(\.element)
        for key in WaterAnalysis.fields {
            let expected = similar.map { $0[keyPath: key] }.reduce(0, +) / Float(similar.count)
            XCTAssertEqual(mean[keyPath: key], expected, accuracy: 1e-5)
        }
    }

    func testSceneInliersKeepSimilarAndTinySets() {
        let similar = (0..<10).map { sample(Float($0) * 0.003) }
        XCTAssertEqual(WaterAnalysis.sceneInliers(similar), Array(0..<10))
        XCTAssertEqual(WaterAnalysis.sceneInliers([sample(0), sample(0.4)]), [0, 1])
        XCTAssertEqual(WaterAnalysis.sceneInliers([sample(0)]), [0])
        XCTAssertEqual(WaterAnalysis.sceneInliers([]), [])
        // Half the clip changes: the most typical half is kept, never fewer.
        let split = (0..<5).map { sample(Float($0) * 0.002) } + (0..<5).map { _ in sample(0.3) }
        XCTAssertGreaterThanOrEqual(WaterAnalysis.sceneInliers(split).count, 5)
        XCTAssertEqual(WaterAnalysis.sceneMean([], keeping: []), .neutral)
    }

    func testSceneAverageUsesKeptPlansAndOneConstantDepth() throws {
        let plans = [try makePlan(depth: 0.4, confidence: 0.5), try makePlan(depth: 0.6, confidence: 0.7),
                     try makePlan(depth: 1.0, confidence: 0.1)]
        let average = try RestorationPlan.sceneAverage(plans, keeping: [0, 1])
        XCTAssertTrue(average.depth.values.allSatisfy { abs($0 - 0.5) < 1e-6 })
        XCTAssertEqual(average.confidence, 0.6, accuracy: 1e-5)
        assertEqual(average.betaDirect, plans[0].betaDirect, accuracy: 1e-6)
        XCTAssertEqual(try RestorationPlan.sceneAverage(plans, keeping: [42]).confidence,
                       (0.5 + 0.7 + 0.1) / 3, accuracy: 1e-5)  // invalid indices fall back to all plans
        XCTAssertThrowsError(try RestorationPlan.sceneAverage([], keeping: []))
    }

    private func makePlan(depth: Float, confidence: Float) throws -> RestorationPlan {
        let map = try NormalizedDepthMap(width: 2, height: 2, values: .init(repeating: depth, count: 4))
        return RestorationPlan(depth: map, depthSource: .monocular,
            depthStatistics: .init(minimum: depth, maximum: depth, median: depth),
            backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
            betaBackscatter: parameters.betaBackscatter, confidence: confidence, limits: .init(),
            transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0)
    }

    private func assertEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 { XCTAssertEqual(lhs[channel], rhs[channel], accuracy: accuracy, file: file, line: line) }
    }
}
