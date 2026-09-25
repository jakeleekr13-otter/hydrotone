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
