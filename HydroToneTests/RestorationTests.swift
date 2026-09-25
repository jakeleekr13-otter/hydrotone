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

    func testDarkFarWaterKeepsItsHue() {
        // Far water that is nearly all veil: green and blue lose most light, red (least
        // recoverable) stays. Without the rule it would turn red-brown or violet.
        let water = SIMD3<Float>(0.02, 0.036, 0.099)
        let restored = RestorationMath.inverse(observed: water, depth: 1, backscatterInfinity: .init(0.043, 0.086, 0.121),
            betaDirect: .init(1.55, 0.9, 0.65), betaBackscatter: .init(1.2, 1.6, 1.6), limits: .init(),
            recoverability: .init(0.44, 1, 1)).color
        XCTAssertEqual(ColorCorrection.oklch(restored).z, ColorCorrection.oklch(water).z, accuracy: 2)
        XCTAssertLessThan(restored.sum(), water.sum())
        // A pixel that keeps most of its light is untouched by the rule.
        let bright = SIMD3<Float>(0.3, 0.5, 0.6)
        let plain = RestorationMath.inverse(observed: bright, depth: 0.3, backscatterInfinity: parameters.infinity,
            betaDirect: parameters.betaDirect, betaBackscatter: parameters.betaBackscatter, limits: .init()).color
        XCTAssertGreaterThan(plain.sum() / bright.sum(), RestorationMath.darkHigh)
    }

    /// Scene values measured on a neon-blue dive photo (a pale wrasse near the camera). At the
    /// video path's constant far depth the veil takes nearly all of the fish's blue.
    private let neonBlue = (infinity: SIMD3<Float>(0.042, 0.057, 0.727), betaDirect: SIMD3<Float>(1.55, 0.9, 0.311),
                            betaBackscatter: SIMD3<Float>(2.47, 0.52, 1.52), recover: SIMD3<Float>(0.08, 1, 1),
                            limits: RestorationLimits(maximumGain: .init(1.377, 1.55, 1.45)))
    private let paleFish = SIMD3<Float>(0.147, 0.229, 0.345)

    func testNearPaleFishAtFarDepthStaysBlueNotLime() {
        let restored = RestorationMath.inverse(observed: paleFish, depth: 0.93, backscatterInfinity: neonBlue.infinity,
            betaDirect: neonBlue.betaDirect, betaBackscatter: neonBlue.betaBackscatter, limits: neonBlue.limits,
            recoverability: neonBlue.recover).color
        // Blue stays the largest channel: no lime, green or yellow.
        XCTAssertGreaterThanOrEqual(restored.z, restored.y)
        XCTAssertGreaterThanOrEqual(restored.z, restored.x)
        XCTAssertEqual(restored.y / restored.z, paleFish.y / paleFish.z, accuracy: 0.02)
        // Far blue water in the same scene keeps its ordinary restoration.
        let water = SIMD3<Float>(0.039, 0.010, 0.806)
        let far = RestorationMath.inverse(observed: water, depth: 0.93, backscatterInfinity: neonBlue.infinity,
            betaDirect: neonBlue.betaDirect, betaBackscatter: neonBlue.betaBackscatter, limits: neonBlue.limits,
            recoverability: neonBlue.recover).color
        assertEqual(RestorationMath.keepBlueFamily(source: water, restored: far), far, accuracy: 1e-6)
    }

    func testBlueFamilyGuardActsOnlyOnBluePixelsThatTurnGreen() {
        // Blue source, blue wiped out: the source hue comes back at the restored level (channel sum).
        let lime = SIMD3<Float>(0.145, 0.317, 0.006)
        let kept = RestorationMath.keepBlueFamily(source: paleFish, restored: lime)
        XCTAssertGreaterThan(kept.z, kept.y)
        XCTAssertGreaterThan(kept.z, kept.x)
        XCTAssertEqual(kept.sum(), lime.sum(), accuracy: 1e-5)
        // Ordinary colour recovery of a blue pixel (green/blue grows less than four times) is untouched.
        let recovered = SIMD3<Float>(0.2, 0.4, 0.3)
        assertEqual(RestorationMath.keepBlueFamily(source: .init(0.1, 0.3, 0.45), restored: recovered), recovered, accuracy: 1e-6)
        // Green and yellow sources stay green or yellow, and neutral sources are untouched.
        for (source, restored): (SIMD3<Float>, SIMD3<Float>) in [
            (.init(0.1, 0.4, 0.2), .init(0.05, 0.5, 0.02)),   // green weed
            (.init(0.4, 0.4, 0.1), .init(0.5, 0.45, 0.01)),   // yellow fish
            (.init(0.3, 0.3, 0.3), .init(0.2, 0.35, 0.03)),   // grey sand
            (.init(0.12, 0.14, 0.13), .init(0.08, 0.16, 0.01))] { // pale cyan, green just above blue
            assertEqual(RestorationMath.keepBlueFamily(source: source, restored: restored), restored, accuracy: 1e-6)
        }
        // Zero and non-finite values stay finite.
        let edge = RestorationMath.keepBlueFamily(source: .zero, restored: .init(0.1, 0.2, 0))
        XCTAssertTrue(edge.x.isFinite && edge.y.isFinite && edge.z.isFinite)
    }

    func testRestorationKernelMatchesCPUMirror() throws {
        let engine = FilterEngine(), restoration = RestorationEngine()
        let infinity = SIMD3<Float>(0.043, 0.086, 0.121), direct = SIMD3<Float>(1.2, 0.6, 0.4), back = SIMD3<Float>(1.2, 1.6, 1.6)
        let recover = SIMD3<Float>(0.44, 1, 1)
        for depth: Float in [0.2, 0.95] {
            let map = try NormalizedDepthMap(width: 4, height: 4, values: .init(repeating: depth, count: 16))
            let plan = RestorationPlan(depth: map, depthSource: .monocular,
                depthStatistics: .init(minimum: depth, maximum: depth, median: depth), backscatterInfinity: infinity,
                betaDirect: direct, betaBackscatter: back, confidence: 0.8, limits: .init(),
                transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0, channelRecoverability: recover)
            // Bright subject, mid water, and dark far water that the dark-pixel rule catches.
            for color: SIMD3<Float> in [.init(0.4, 0.5, 0.55), .init(0.06, 0.12, 0.3), .init(0.02, 0.036, 0.099)] {
                let image = CIImage(color: CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                                                   colorSpace: FilterEngine.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
                var pixel = [Float](repeating: 0, count: 4)
                engine.context.render(try restoration.restore(image, plan: plan), toBitmap: &pixel, rowBytes: 16,
                                      bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
                let expected = RestorationMath.inverse(observed: color, depth: depth, backscatterInfinity: infinity,
                    betaDirect: direct, betaBackscatter: back, limits: plan.limits, recoverability: recover).color
                assertEqual(SIMD3(pixel[0], pixel[1], pixel[2]), expected, accuracy: 0.004 * max(1, expected.max()))
            }
        }
        // The blue-family guard: a near pale fish at far depth (guarded), the far water and a
        // green pixel (not guarded), in the neon-blue scene.
        let map = try NormalizedDepthMap(width: 4, height: 4, values: .init(repeating: 0.93, count: 16))
        let plan = RestorationPlan(depth: map, depthSource: .monocular, depthStatistics: .init(minimum: 0.93, maximum: 0.93, median: 0.93),
            backscatterInfinity: neonBlue.infinity, betaDirect: neonBlue.betaDirect, betaBackscatter: neonBlue.betaBackscatter,
            confidence: 0.8, limits: neonBlue.limits, transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0,
            channelRecoverability: neonBlue.recover)
        for color: SIMD3<Float> in [paleFish, .init(0.039, 0.010, 0.806), .init(0.1, 0.4, 0.2), .init(0.2, 0.3, 0.42)] {
            let image = CIImage(color: CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                                               colorSpace: FilterEngine.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            var pixel = [Float](repeating: 0, count: 4)
            engine.context.render(try restoration.restore(image, plan: plan), toBitmap: &pixel, rowBytes: 16,
                                  bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            let expected = RestorationMath.inverse(observed: color, depth: 0.93, backscatterInfinity: neonBlue.infinity,
                betaDirect: neonBlue.betaDirect, betaBackscatter: neonBlue.betaBackscatter, limits: plan.limits,
                recoverability: neonBlue.recover).color
            assertEqual(SIMD3(pixel[0], pixel[1], pixel[2]), expected, accuracy: 0.004 * max(1, expected.max()))
        }
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
            $0.midLift = 0.5; $0.toneCurve = 0.25; $0.tonePivot = 0.42
            $0.waterTone = .init(0.8, 1.15, 0.7); $0.waterRedness = 0.12
            $0.waterSaturation = 0.6; $0.waterChroma = 0.8; $0.redCeiling = 1.05; $0.violetGuard = 0.7 }
        // Water-like, partly water-like, grey (silver) and subject colours, a blue pixel whose red
        // passes green (violet guard), and a gated pixel whose rebuilt red hits the ceiling.
        for color: SIMD3<Float> in [.init(0.05, 0.3, 0.35), .init(0.3, 0.25, 0.2), .init(0.02, 0.5, 0.3), .init(2.5, 3, 4),
                                    .init(0.02, 0.15, 0.4), .init(0.06, 0.2, 0.3), .init(0.3, 0.33, 0.38),
                                    .init(0.05, 0.02, 0.5), .init(0.2, 0.3, 0.33)] {
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

    // MARK: Water tone and neutral scenes

    /// A scene whose open water has the given colour; the scene mean is a little redder.
    private func scene(water: SIMD3<Float>, mid: Float = 0.12, contrast: Float = 0.2) -> WaterAnalysis {
        let mean = water + SIMD3(0.04, 0.02, 0)
        let surviving = (mean.y + mean.z) / 2
        return WaterAnalysis(redLoss: max(0, 1 - mean.x / surviving), cyanDominance: max(0, 1 - mean.x / surviving),
                             exposure: 0.02, contrast: contrast, saturation: 0.6, meanRed: mean.x, meanGreen: mean.y,
                             meanBlue: mean.z, midLuminance: mid, waterRed: water.x, waterGreen: water.y, waterBlue: water.z)
    }

    private func toned(_ water: SIMD3<Float>, _ values: ColorCorrection) -> SIMD3<Float> {
        FinishingMath.color(water, correction: { var v = values; v.redRebuild = 0; v.midLift = 0; v.toneCurve = 0; return v }())
    }

    private func oklch(_ c: SIMD3<Float>) -> SIMD3<Float> { ColorCorrection.oklch(c) }

    func testOKLabSeparatesBluesThatCIELABMerges() {
        // Linear Rec. 2020 colours of an azure and an indigo: OKLab puts them in different bands.
        let azure = SIMD3<Float>(0.02, 0.2, 0.75), indigo = SIMD3<Float>(0.06, 0.02, 0.5)
        XCTAssertLessThan(oklch(azure).z, 262)
        XCTAssertGreaterThan(oklch(indigo).z, 270)
        XCTAssertEqual(oklch(.init(repeating: 0.4)).y, 0, accuracy: 1e-4)
    }

    func testOKLabWaterCorrectionHitsItsTarget() {
        let from = SIMD3<Float>(0.068, 0.118, 0.395)  // mid-blue water, OKLab hue about 255
        let target = SIMD3<Float>(oklch(from).x, 0.1, 240)
        let result = ColorCorrection.waterCorrection(from: from, to: target)
        let out = oklch(ColorCorrection.toned(from, gains: result.gains, saturation: result.saturation))
        XCTAssertEqual(out.y, 0.1, accuracy: 0.005)
        XCTAssertEqual(out.z, 240, accuracy: 1.5)
        // Luminance is kept.
        let before = (from * ColorCorrection.luma).sum()
        let after = (ColorCorrection.toned(from, gains: result.gains, saturation: result.saturation) * ColorCorrection.luma).sum()
        XCTAssertEqual(after, before, accuracy: before * 0.01)
        let broken = ColorCorrection.waterCorrection(from: .init(.nan, 0.1, 0.1), to: target)
        XCTAssertEqual(broken.gains, .one)
        XCTAssertEqual(broken.saturation, 1)
    }

    func testWaterTargetNeverPointsTowardIndigoOrViolet() {
        // Every water hue up to 285 gets a target inside the cyan-to-blue band 215...265.
        // (285...290 is the fade toward "not water"; see waterPlausibility.)
        for hue in stride(from: Float(150), through: 285, by: 5) {
            let target = ColorCorrection.waterTarget(.init(0.45, 0.15, hue), waterType: 0, murky: 0)
            XCTAssertGreaterThanOrEqual(target.z, 215, "hue \(hue)")
            XCTAssertLessThanOrEqual(target.z, 265, "hue \(hue)")
        }
        // Inside the band the hue is only nudged, never pushed across it.
        for hue: Float in [230, 245, 258] {
            let target = ColorCorrection.waterTarget(.init(0.45, 0.15, hue), waterType: 0, murky: 0)
            XCTAssertLessThanOrEqual(abs(target.z - hue), 12)
            XCTAssertLessThanOrEqual(target.z, max(hue, 262))
        }
        // A frame-filling magenta anemone (hue 295) is not water: no change at all.
        let anemone = SIMD3<Float>(0.5, 0.28, 295)
        XCTAssertEqual(ColorCorrection.waterTarget(anemone, waterType: 0, murky: 0), anemone)
        XCTAssertEqual(ColorCorrection.waterPlausibility(anemone), 0)
    }

    func testIndigoWaterMovesIntoTheBlueBand() {
        let indigo = SIMD3<Float>(0.05, 0.03, 0.3)  // OKLab hue about 274
        XCTAssertGreaterThan(oklch(indigo).z, 270)
        let values = ColorCorrection.make(analysis: scene(water: indigo), preset: .natural)
        let hue = oklch(toned(indigo, values)).z
        XCTAssertLessThan(hue, 265)
        XCTAssertGreaterThan(hue, 215)
    }

    func testNeonWaterChromaGoesDownAndStaysBlue() {
        let neon = SIMD3<Float>(0.039, 0.010, 0.804)  // phone-camera neon blue, OKLab chroma about 0.30
        XCTAssertGreaterThan(oklch(neon).y, 0.28)
        let values = ColorCorrection.make(analysis: scene(water: neon, mid: 0.07, contrast: 0.06), preset: .natural)
        let out = oklch(toned(neon, values))
        XCTAssertLessThan(out.y, 0.14)
        XCTAssertGreaterThan(out.y, 0.04)          // calmed, not grey
        XCTAssertLessThan(out.z, 265)             // never toward indigo
        XCTAssertGreaterThan(out.z, 215)
        XCTAssertLessThan(values.waterSaturation, 1)
    }

    func testWaterTypeIsContinuousAndTealCountsAsGreen() {
        func type(_ water: SIMD3<Float>) -> Float { ColorCorrection.waterType(scene(water: water)) }
        XCTAssertEqual(type(.init(0.02, 0.07, 0.25)), 0, accuracy: 1e-6)      // deep blue
        XCTAssertEqual(type(.init(0.01, 0.1, 0.1)), 1, accuracy: 1e-6)        // teal: green about equal to blue, no red
        XCTAssertEqual(type(.init(0.05, 0.3, 0.15)), 1, accuracy: 1e-6)       // green
        // Teal counts toward green through the red it lost: same green/blue, more red, lower type.
        XCTAssertGreaterThan(type(.init(0.005, 0.07, 0.1)), type(.init(0.06, 0.07, 0.1)) + 0.05)
        // Continuous: small changes in the water colour give small changes in the type.
        var previous = type(.init(0.02, 0.05, 0.2))
        for step in 1...40 {
            let green = 0.05 + Float(step) * 0.004
            let now = type(.init(0.02, green, 0.2))
            XCTAssertLessThanOrEqual(abs(now - previous), 0.08)
            XCTAssertGreaterThanOrEqual(now, previous - 1e-6)
            previous = now
        }
        // A neutral scene is not water.
        let grey = WaterAnalysis(meanRed: 0.2, meanGreen: 0.2, meanBlue: 0.2, midLuminance: 0.2,
                                 waterRed: 0.1, waterGreen: 0.1, waterBlue: 0.1)
        XCTAssertEqual(ColorCorrection.waterType(grey), 0)
        XCTAssertEqual(ColorCorrection.make(analysis: scene(water: .init(0.01, 0.1, 0.1)), preset: .natural).waterType, 1, accuracy: 1e-6)
    }

    func testTealWaterBecomesCyanBlueAndDeepMurkyWaterGetsColour() {
        let teal = SIMD3<Float>(0.02, 0.06, 0.055)
        XCTAssertLessThan(oklch(teal).z, 205)
        let shallow = ColorCorrection.make(analysis: scene(water: teal, mid: 0.3, contrast: 0.3), preset: .natural)
        let murky = ColorCorrection.make(analysis: scene(water: teal, mid: 0.04, contrast: 0.05), preset: .natural)
        for values in [shallow, murky] {
            let hue = oklch(toned(teal, values)).z
            XCTAssertGreaterThanOrEqual(hue, 222)
            XCTAssertLessThanOrEqual(hue, 262)
        }
        XCTAssertGreaterThan(oklch(toned(teal, murky)).y, oklch(toned(teal, shallow)).y)
    }

    func testWaterToneSkipsRedderSubjects() {
        let values = colorOnly { $0.castGains = .init(repeating: 1); $0.waterTone = .init(0.7, 1.2, 0.7); $0.waterRedness = 0.1 }
        let water = SIMD3<Float>(0.02, 0.1, 0.3)     // redness 0.05: fully toned
        let subject = SIMD3<Float>(0.3, 0.25, 0.2)   // redness 0.67: untouched
        assertEqual(FinishingMath.color(water, correction: values), water * values.waterTone, accuracy: 1e-5)
        assertEqual(FinishingMath.color(subject, correction: values), subject, accuracy: 1e-5)
    }

    func testSilverFishInBlueWaterIsNotToned() {
        let water = SIMD3<Float>(0.068, 0.118, 0.395)
        let values = ColorCorrection.make(analysis: scene(water: water), preset: .natural)
        XCTAssertNotEqual(values.waterTone, .one)
        let silver = SIMD3<Float>(0.30, 0.34, 0.40)  // much greyer than the water
        let untoned = { var v = values; v.waterTone = .one; v.waterSaturation = 1; return v }()
        assertEqual(FinishingMath.color(silver, correction: values), FinishingMath.color(silver, correction: untoned), accuracy: 1e-5)
        // And it stays silver: no orange, no cyan.
        let out = FinishingMath.color(silver, correction: { var v = values; v.midLift = 0; v.toneCurve = 0; return v }())
        XCTAssertLessThan(oklch(out).y, 0.04)
    }

    func testSimilarMurkyWaterColoursDoNotBecomeContrastingPatches() {
        // Two compressed water colours differ by at most five sRGB code values.
        // Previously the subject mask amplified their difference to about 16 deltaE,
        // creating visible grey/blue blocks beside otherwise smooth water.
        let values = colorOnly {
            $0.castGains = .init(1.16, 0.97, 1.01); $0.waterTone = .init(0.98, 0.92, 1.59)
            $0.waterRedness = 0.26; $0.waterChroma = 0.54; $0.waterSaturation = 1.6
            $0.redRebuild = 0.24; $0.redGateLow = 0.52; $0.redGateHigh = 0.92; $0.subjectRed = 0.4
            $0.toneCurve = 0.3; $0.tonePivot = 0.3
        }
        let engine = FilterEngine(), sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var labs: [SIMD3<Float>] = [], display: [[UInt8]] = []
        for rgb: SIMD3<Float> in [.init(29, 70, 72), .init(34, 73, 70)] {
            let source = CIImage(color: CIColor(red: CGFloat(rgb.x / 255), green: CGFloat(rgb.y / 255),
                                                blue: CGFloat(rgb.z / 255), colorSpace: sRGB)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let result = engine.finishing(source, correction: values)
            var linear = [Float](repeating: 0, count: 4), encoded = [UInt8](repeating: 0, count: 4)
            let bounds = CGRect(x: 4, y: 4, width: 1, height: 1)
            engine.context.render(result, toBitmap: &linear, rowBytes: 16, bounds: bounds,
                                  format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            engine.context.render(result, toBitmap: &encoded, rowBytes: 4, bounds: bounds,
                                  format: .RGBA8, colorSpace: sRGB)
            labs.append(ColorCorrection.lab(.init(linear[0], linear[1], linear[2])))
            display.append(encoded)
        }
        let difference = labs[0] - labs[1]
        XCTAssertLessThan(sqrt((difference * difference).sum()), 8)
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(display[0][channel]) - Int(display[1][channel])), 24)
        }
    }

    func testRebuiltRedStopsAtGreen() {
        let values = colorOnly { $0.castGains = .init(repeating: 1); $0.redRebuild = 3; $0.subjectRed = 0.1; $0.redCeiling = 1.05 }
        let reef = SIMD3<Float>(0.05, 0.3, 0.35)      // inside the gate, lots of red to rebuild
        let out = FinishingMath.color(reef, correction: values)
        XCTAssertEqual(out.x, reef.y * 1.05, accuracy: 1e-4)
        let red = SIMD3<Float>(0.5, 0.3, 0.35)        // already redder than the ceiling: no change
        XCTAssertEqual(FinishingMath.color(red, correction: values).x, red.x, accuracy: 1e-5)
    }

    func testVioletGuardKeepsBlueWaterFromTurningViolet() {
        // A red boost on blue water with red above green would read violet.
        var values = colorOnly { $0.castGains = .init(1.4, 1, 1); $0.waterRedness = 0.1; $0.waterChroma = 0.9; $0.violetGuard = 1 }
        let neon = SIMD3<Float>(0.04, 0.01, 0.8)
        let guarded = FinishingMath.color(neon, correction: values)
        XCTAssertLessThanOrEqual(guarded.x, guarded.y + 1e-5)       // water-like: red stops at green
        XCTAssertLessThan(oklch(guarded).z, oklch(neon * values.castGains).z)
        // Without the water strength (a magenta anemone "water"), red may not pass its own source red.
        values.violetGuard = 0
        let anemone = FinishingMath.color(neon, correction: values)
        XCTAssertEqual(anemone.x, neon.x, accuracy: 1e-5)
    }

    func testBlueTintedSubjectGetsRedButDeepBlueWaterDoesNot() {
        let water = SIMD3<Float>(0.02, 0.07, 0.25)
        let values = ColorCorrection.make(analysis: scene(water: water), preset: .natural)
        let reef = SIMD3<Float>(0.06, 0.2, 0.22)     // blue-green reef, greener than the water
        let reefOut = FinishingMath.color(reef, correction: { var v = values; v.midLift = 0; v.toneCurve = 0; return v }())
        let reefToned = toned(reef, { var v = values; v.redRebuild = 0; return v }())
        XCTAssertGreaterThan(reefOut.x / reefOut.y, reefToned.x / reefToned.y + 0.05)
        let waterOut = FinishingMath.color(water, correction: { var v = values; v.midLift = 0; v.toneCurve = 0; return v }())
        XCTAssertEqual(waterOut.x, toned(water, values).x, accuracy: 1e-4) // the water itself gets no rebuilt red
    }

    func testNeonWaterGetsLessSaturation() {
        let calm = ColorCorrection.make(analysis: scene(water: .init(0.03, 0.08, 0.16)), preset: .natural)
        let neon = ColorCorrection.make(analysis: scene(water: .init(0.001, 0.02, 0.4)), preset: .natural)
        XCTAssertGreaterThan(calm.saturation, 1)
        XCTAssertLessThan(neon.saturation, calm.saturation)
    }

    func testNeutralScenesStayNeutralOnBothPaths() throws {
        // A grey ramp: no cast, so no channel may be treated differently.
        let grey = WaterAnalysis(redLoss: 0, cyanDominance: 0, exposure: 0, contrast: 0.6, saturation: 0,
                                 meanRed: 0.2, meanGreen: 0.2, meanBlue: 0.2, midLuminance: 0.2,
                                 waterRed: 0.1, waterGreen: 0.1, waterBlue: 0.1)
        XCTAssertEqual(grey.castStrength, 0)
        let width = 64, height = 16
        let ramp = (0..<(width * height)).map { Float($0 % width) / Float(width - 1) }
        var rgba = [Float](); rgba.reserveCapacity(ramp.count * 4)
        for value in ramp { rgba += [0.05 + value * 0.85, 0.05 + value * 0.85, 0.05 + value * 0.85, 1] }
        let data = rgba.withUnsafeBytes { Data($0) }
        let source = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                             format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        let map = try NormalizedDepthMap(width: width, height: height, values: ramp)
        let depth = DepthEstimate(map: map, source: .monocular, statistics: .init(minimum: 0, maximum: 1, median: 0.5),
                                  confidence: 0.9, inferenceMilliseconds: nil)
        let plan = try WaterModelEstimator().estimate(image: source, depth: depth, legacy: grey, context: FilterEngine().context)
        XCTAssertEqual(plan.betaDirect.x, plan.betaDirect.y, accuracy: 1e-5)
        XCTAssertEqual(plan.betaDirect.y, plan.betaDirect.z, accuracy: 1e-5)
        XCTAssertEqual(plan.limits.maximumGain.x, plan.limits.maximumGain.z, accuracy: 1e-5)
        for values in [ColorCorrection.make(analysis: grey, preset: .natural),
                       ColorCorrection.make(analysis: grey, preset: .natural, plan: plan)] {
            assertEqual(values.waterTone, .one, accuracy: 1e-6)
            XCTAssertEqual(values.waterSaturation, 1, accuracy: 1e-6)
            XCTAssertEqual(values.waterType, 0)
            XCTAssertEqual(values.castGains.x, values.castGains.z, accuracy: 1e-6)
            for level: Float in [0.05, 0.2, 0.5, 0.8] {
                let pixel = RestorationMath.inverse(observed: .init(repeating: level), depth: 0.7,
                    backscatterInfinity: plan.backscatterInfinity, betaDirect: plan.betaDirect,
                    betaBackscatter: plan.betaBackscatter, limits: plan.limits,
                    recoverability: plan.channelRecoverability).color
                let out = FinishingMath.color(pixel, correction: values)
                XCTAssertEqual(ColorCorrection.lightnessChromaHue(out).y, 0, accuracy: 1)
            }
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

    func testSceneInliersKeepFramesWithAndWithoutANeutralSurface() {
        // The same water in every frame; sand shows in 7 of 10 frames. "No surface" is not an odd frame.
        let samples = (0..<10).map { index -> WaterAnalysis in
            var s = sample(Float(index) * 0.003)
            if index >= 3 { s.neutralRed = 0.4; s.neutralGreen = 0.5; s.neutralBlue = 0.5; s.neutralShare = 0.05 }
            s.highShare = index == 5 ? 0.12 : 0.01
            return s
        }
        XCTAssertEqual(WaterAnalysis.sceneInliers(samples), Array(0..<10))
    }

    func testSceneMeanAveragesTheNeutralColourOnlyWhereItWasFound() {
        var found = sample(0), strong = sample(0), none = sample(0)
        found.neutralRed = 0.4; found.neutralGreen = 0.5; found.neutralBlue = 0.5; found.neutralShare = 0.02
        strong.neutralRed = 0.1; strong.neutralGreen = 0.2; strong.neutralBlue = 0.2; strong.neutralShare = 0.06
        let mean = WaterAnalysis.sceneMean([found, strong, none], keeping: [0, 1, 2])
        // Weighted by evidence; the frame without a surface does not darken the colour.
        XCTAssertEqual(mean.neutralRed, (0.4 * 0.02 + 0.1 * 0.06) / 0.08, accuracy: 1e-6)
        XCTAssertEqual(mean.neutralGreen, (0.5 * 0.02 + 0.2 * 0.06) / 0.08, accuracy: 1e-6)
        XCTAssertEqual(mean.neutralBlue, (0.5 * 0.02 + 0.2 * 0.06) / 0.08, accuracy: 1e-6)
        // The evidence itself is the plain mean, so a surface seen in few frames counts for less.
        XCTAssertEqual(mean.neutralShare, 0.08 / 3, accuracy: 1e-6)
        XCTAssertEqual(WaterAnalysis.sceneMean([none, none], keeping: [0, 1]).neutralColor, .zero)
    }

    func testSceneAverageUsesKeptPlansAndOneConstantDepth() throws {
        let plans = [try makePlan(depth: 0.4, confidence: 0.5), try makePlan(depth: 0.6, confidence: 0.7),
                     try makePlan(depth: 1.0, confidence: 0.1)]
        let average = try RestorationPlan.sceneAverage(plans, keeping: [0, 1])
        XCTAssertTrue(average.depth.values.allSatisfy { abs($0 - 0.5) < 1e-6 })
        XCTAssertEqual(average.confidence, 0.6, accuracy: 1e-5)
        assertEqual(average.betaDirect, plans[0].betaDirect, accuracy: 1e-6)
        XCTAssertEqual(try RestorationPlan.sceneAverage(plans, keeping: [42, 1]).confidence, 0.7, accuracy: 1e-5)
        XCTAssertThrowsError(try RestorationPlan.sceneAverage(plans, keeping: [42]))
        XCTAssertThrowsError(try RestorationPlan.sceneAverage([], keeping: []))
    }

    func testSceneAverageDoesNotRestoreRejectedPlansWhenAcceptedDepthFitsFailed() throws {
        // The only successful fit belongs to a rejected sample. Keeping no plan must
        // trigger the existing fallback instead of using that unrelated environment.
        let rejected = try makePlan(depth: 1, confidence: 0.9)
        XCTAssertThrowsError(try RestorationPlan.sceneAverage([rejected], keeping: []))
    }

    // MARK: White reference and highlight rule

    /// A shallow blue scene with pale sand under a strong cyan cast (numbers close to market pair m5).
    private func sandScene(share: Float = 0.2) -> WaterAnalysis {
        var analysis = scene(water: .init(0.01, 0.23, 0.65), mid: 0.2, contrast: 0.3)
        analysis.neutralRed = 0.28; analysis.neutralGreen = 0.59; analysis.neutralBlue = 0.67
        analysis.neutralShare = share; analysis.highShare = 0.3
        return analysis
    }

    private func finishedChroma(_ c: SIMD3<Float>, _ values: ColorCorrection) -> Float {
        oklch(FinishingMath.color(c, correction: values)).y
    }

    func testCyanCastSurfaceBecomesNearlyNeutral() throws {
        let analysis = sandScene(), sand = analysis.neutralColor
        let current = ColorCorrection.make(analysis: analysis, preset: .natural)
        var without = current; without.neutralGains = .one
        XCTAssertGreaterThan(finishedChroma(sand, without), 0.05)
        XCTAssertLessThan(finishedChroma(sand, current), 0.02)
        // Restored path: the sand is seen after veil removal, at the plan's (constant) depth.
        // Near sand keeps a cyan cast after restoration; the rule removes it.
        var acted = false
        for depth: Float in [0.1, 0.5] {
            let plan = try makePlan(depth: depth, confidence: 0.7)
            let restored = ColorCorrection.make(analysis: analysis, preset: .natural, plan: plan)
            let seen = RestorationMath.inverse(observed: sand, depth: depth, backscatterInfinity: plan.backscatterInfinity,
                                               betaDirect: plan.betaDirect, betaBackscatter: plan.betaBackscatter,
                                               limits: plan.limits, recoverability: plan.channelRecoverability).color
            var restoredWithout = restored; restoredWithout.neutralGains = .one
            XCTAssertLessThan(finishedChroma(seen, restored), 0.02)
            XCTAssertLessThanOrEqual(finishedChroma(seen, restored), finishedChroma(seen, restoredWithout) + 1e-6)
            if finishedChroma(seen, restoredWithout) > 0.04 { acted = true }
        }
        XCTAssertTrue(acted, "no restored case kept a cast for the rule to remove")
        // Red goes up, blue goes down, and green never rises more than 5%.
        XCTAssertGreaterThan(current.neutralGains.x, 1)
        XCTAssertLessThan(current.neutralGains.z, 1)
        XCTAssertLessThanOrEqual(current.neutralGains.y, 1.05 + 1e-5)
    }

    func testWhiteReferenceDoesNotNeutraliseTheWater() {
        let analysis = sandScene(), water = analysis.waterColor
        let values = ColorCorrection.make(analysis: analysis, preset: .natural)
        XCTAssertNotEqual(values.neutralGains, .one)
        var without = values; without.neutralGains = .one
        // Open water, and brighter water of the same colour, keep exactly their colour.
        for pixel in [water, water * 1.6] {
            let with = FinishingMath.color(pixel, correction: values), plain = FinishingMath.color(pixel, correction: without)
            assertEqual(with, plain, accuracy: 1e-3 * max(1, plain.max()))
            let lch = oklch(with)
            XCTAssertGreaterThan(lch.y, 0.03)          // still coloured
            XCTAssertGreaterThan(lch.z, 180)           // cyan to blue, not indigo
            XCTAssertLessThan(lch.z, 270)
        }
        // A strongly blue "reference" looks like pale water near the surface, so it is ignored.
        var paleWater = analysis
        paleWater.neutralRed = 0.16; paleWater.neutralGreen = 0.34; paleWater.neutralBlue = 0.72
        XCTAssertEqual(ColorCorrection.make(analysis: paleWater, preset: .natural).neutralGains, .one)
    }

    func testSceneWithoutNeutralSurfacesIsUnchangedByTheWhiteReference() throws {
        let plan = try makePlan(depth: 0.6, confidence: 0.6)
        var none = sandScene(); none.neutralRed = 0; none.neutralGreen = 0; none.neutralBlue = 0; none.neutralShare = 0
        let tooFew = sandScene(share: 0.005)       // a few pixels: not enough evidence
        var warm = sandScene()                     // a warm surface is a real colour, not a cast
        warm.neutralRed = 0.6; warm.neutralGreen = 0.45; warm.neutralBlue = 0.3
        for analysis in [none, tooFew, warm] {
            for values in [ColorCorrection.make(analysis: analysis, preset: .natural),
                           ColorCorrection.make(analysis: analysis, preset: .natural, plan: plan)] {
                XCTAssertEqual(values.neutralGains, .one)
                var reference = values; reference.neutralGains = .one
                XCTAssertEqual(values, reference)
            }
        }
        // Gains of one leave every pixel as it was without the rule.
        let values = ColorCorrection.make(analysis: none, preset: .natural)
        for pixel: SIMD3<Float> in [.init(0.3, 0.33, 0.38), .init(0.02, 0.2, 0.6), .init(0.5, 0.3, 0.2)] {
            var plain = values; plain.waterLit = .zero
            assertEqual(FinishingMath.color(pixel, correction: values), FinishingMath.color(pixel, correction: plain), accuracy: 1e-6)
        }
    }

    func testLargeBrightSubjectGetsLessLift() throws {
        // The same hazy scene with and without a large bright subject (a white belly).
        let plain = scene(water: .init(0.02, 0.25, 0.4), mid: 0.2, contrast: 0.18)
        var belly = plain; belly.highShare = 0.12
        let plan = try makePlan(depth: 0.6, confidence: 0.7)
        let without = ColorCorrection.make(analysis: plain, preset: .natural, plan: plan)
        let with = ColorCorrection.make(analysis: belly, preset: .natural, plan: plan)
        XCTAssertGreaterThan(without.midLift, 0)
        XCTAssertLessThan(with.midLift, without.midLift)
        XCTAssertLessThan(with.brightness, without.brightness)
        XCTAssertLessThan(with.shadowLift, without.shadowLift)
        // A dark scene with a few bright spots keeps its lift: there the spots do not light the scene.
        let dark = scene(water: .init(0.01, 0.05, 0.08), mid: 0.05, contrast: 0.1)
        var spots = dark; spots.highShare = 0.12
        XCTAssertEqual(ColorCorrection.make(analysis: spots, preset: .natural, plan: plan),
                       ColorCorrection.make(analysis: dark, preset: .natural, plan: plan))
    }

    func testNeutralRampStaysNeutralWithWhiteReferenceOnBothPaths() throws {
        // A grey scene whose bright grey surfaces are found as the reference: nothing may tint it.
        var grey = WaterAnalysis(redLoss: 0, cyanDominance: 0, exposure: 0, contrast: 0.6, saturation: 0,
                                 meanRed: 0.2, meanGreen: 0.2, meanBlue: 0.2, midLuminance: 0.2,
                                 waterRed: 0.1, waterGreen: 0.1, waterBlue: 0.1)
        grey.neutralRed = 0.5; grey.neutralGreen = 0.5; grey.neutralBlue = 0.5; grey.neutralShare = 0.2; grey.highShare = 0.3
        let plan = try makePlan(depth: 0.5, confidence: 0.7)
        let uniform = try plan.sceneLevel()
        for values in [ColorCorrection.make(analysis: grey, preset: .natural),
                       ColorCorrection.make(analysis: grey, preset: .natural, plan: plan),
                       ColorCorrection.make(analysis: grey, preset: .natural, plan: uniform)] {
            for level: Float in [0.05, 0.2, 0.5, 0.8] {
                let out = FinishingMath.color(.init(repeating: level), correction: values)
                XCTAssertEqual(ColorCorrection.lightnessChromaHue(out).y, 0, accuracy: 1)
            }
        }
    }

    func testFinishingKernelMatchesCPUMirrorWithWhiteReference() {
        let engine = FilterEngine()
        let values = colorOnly { $0.castGains = .init(1.2, 0.97, 0.97); $0.redRebuild = 0.3; $0.subjectRed = 0.3
            $0.redGateLow = 0.6; $0.redGateHigh = 1.0; $0.midLift = 0.3; $0.toneCurve = 0.2; $0.tonePivot = 0.45
            $0.waterTone = .init(0.9, 1.05, 0.95); $0.waterRedness = 0.03; $0.waterSaturation = 0.8
            $0.waterChroma = 0.9; $0.violetGuard = 0.8
            $0.neutralGains = .init(1.6, 0.95, 0.8); $0.waterLit = .init(0.01, 0.25, 0.4) }
        // Water, brighter water of the same colour, a pale belly (bright, other hue), sand, a reddish
        // subject, a dark pixel and an HDR peak.
        for color: SIMD3<Float> in [.init(0.01, 0.25, 0.4), .init(0.016, 0.4, 0.64), .init(0.03, 0.48, 0.49),
                                    .init(0.28, 0.59, 0.67), .init(0.3, 0.25, 0.2), .init(0.01, 0.03, 0.05),
                                    .init(1.5, 2, 2.2)] {
            let image = CIImage(color: CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z),
                                               colorSpace: FilterEngine.workingSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            var pixel = [Float](repeating: 0, count: 4)
            engine.context.render(engine.finishing(image, correction: values), toBitmap: &pixel, rowBytes: 16,
                                  bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            let expected = FinishingMath.color(color, correction: values)
            assertEqual(SIMD3(pixel[0], pixel[1], pixel[2]), expected, accuracy: 0.004 * max(1, expected.max()))
        }
        // The belly takes the reference, the water does not.
        XCTAssertGreaterThan(FinishingMath.neutralWeight(.init(0.03, 0.48, 0.49) * values.castGains, correction: values), 0.9)
        XCTAssertLessThan(FinishingMath.neutralWeight(.init(0.016, 0.4, 0.64) * values.castGains, correction: values), 0.1)
    }

    func testAnalysisFindsBrightNeutralSurfacesAndBrightShare() {
        // Left: blue water. Right: pale sand under the cast, brighter than the water.
        let width = 48, height = 48
        var rgba = [Float]()
        for _ in 0..<height { for x in 0..<width {
            rgba += x < 30 ? [0.02, 0.2, 0.55, 1] : [0.3, 0.6, 0.66, 1]
        } }
        let data = rgba.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                            format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        let analysis = FilterEngine().analyze(image)
        XCTAssertGreaterThan(analysis.neutralShare, 0.1)
        XCTAssertGreaterThan(analysis.neutralGreen, analysis.waterGreen)
        XCTAssertGreaterThan(analysis.neutralRed, 0.2)
        XCTAssertGreaterThan(analysis.highShare, 0.3)
        // Water only: no reference and no bright area.
        let water = CIImage(color: CIColor(red: 0.02, green: 0.2, blue: 0.55, colorSpace: FilterEngine.workingSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 48))
        let plain = FilterEngine().analyze(water)
        XCTAssertEqual(plain.neutralShare, 0)
        XCTAssertEqual(plain.highShare, 0)
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
