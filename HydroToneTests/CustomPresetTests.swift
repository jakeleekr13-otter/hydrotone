import XCTest
import CoreImage
import simd
@testable import HydroTone

final class CustomPresetTests: XCTestCase {
    private let parameters = (
        infinity: SIMD3<Float>(0.08, 0.18, 0.32),
        betaDirect: SIMD3<Float>(0.9, 0.45, 0.25),
        betaBackscatter: SIMD3<Float>(0.55, 0.42, 0.31)
    )
    private let sliders: [WritableKeyPath<CustomAdjustments, Float>] = [\.brightness, \.contrast, \.saturation, \.clarity, \.temperature]

    // MARK: Helpers (the same scene and plan shapes as RestorationTests)

    private func scene(water: SIMD3<Float>, mid: Float = 0.12, contrast: Float = 0.2) -> WaterAnalysis {
        let mean = water + SIMD3(0.04, 0.02, 0)
        let surviving = (mean.y + mean.z) / 2
        return WaterAnalysis(redLoss: max(0, 1 - mean.x / surviving), cyanDominance: max(0, 1 - mean.x / surviving),
                             exposure: 0.02, contrast: contrast, saturation: 0.6, meanRed: mean.x, meanGreen: mean.y,
                             meanBlue: mean.z, midLuminance: mid, waterRed: water.x, waterGreen: water.y, waterBlue: water.z)
    }
    private func sandScene() -> WaterAnalysis {
        var analysis = scene(water: .init(0.01, 0.23, 0.65), mid: 0.2, contrast: 0.3)
        analysis.neutralRed = 0.28; analysis.neutralGreen = 0.59; analysis.neutralBlue = 0.67
        analysis.neutralShare = 0.2; analysis.highShare = 0.3
        return analysis
    }
    private func greyScene() -> WaterAnalysis {
        var grey = WaterAnalysis(redLoss: 0, cyanDominance: 0, exposure: 0, contrast: 0.6, saturation: 0,
                                 meanRed: 0.2, meanGreen: 0.2, meanBlue: 0.2, midLuminance: 0.2,
                                 waterRed: 0.1, waterGreen: 0.1, waterBlue: 0.1)
        grey.neutralRed = 0.5; grey.neutralGreen = 0.5; grey.neutralBlue = 0.5; grey.neutralShare = 0.2; grey.highShare = 0.3
        return grey
    }
    /// Blue, green, teal, neon, deep murky, a white-reference scene and a grey scene.
    private var scenes: [WaterAnalysis] {
        [scene(water: .init(0.02, 0.25, 0.4), mid: 0.2, contrast: 0.3), scene(water: .init(0.03, 0.3, 0.2)),
         scene(water: .init(0.02, 0.3, 0.3), mid: 0.15), scene(water: .init(0.001, 0.02, 0.4)),
         scene(water: .init(0.005, 0.04, 0.06), mid: 0.05, contrast: 0.1), sandScene(), greyScene()]
    }
    private func makePlan(depth: Float, confidence: Float) throws -> RestorationPlan {
        let map = try NormalizedDepthMap(width: 2, height: 2, values: .init(repeating: depth, count: 4))
        return RestorationPlan(depth: map, depthSource: .monocular,
            depthStatistics: .init(minimum: depth, maximum: depth, median: depth),
            backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
            betaBackscatter: parameters.betaBackscatter, confidence: confidence, limits: .init(),
            transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0)
    }
    private func plans() throws -> [RestorationPlan?] { [nil, try makePlan(depth: 0.6, confidence: 0.55), try makePlan(depth: 0.2, confidence: 0.8)] }
    private func adjust(_ key: WritableKeyPath<CustomAdjustments, Float>, _ value: Float) -> CustomAdjustments {
        var a = CustomAdjustments(); a[keyPath: key] = value; return a
    }
    /// Every slider alone at -1 and +1, and all five at -1 and at +1.
    private var extremes: [CustomAdjustments] {
        sliders.flatMap { [adjust($0, -1), adjust($0, 1)] }
            + [CustomAdjustments(brightness: -1, contrast: -1, saturation: -1, clarity: -1, temperature: -1),
               CustomAdjustments(brightness: 1, contrast: 1, saturation: 1, clarity: 1, temperature: 1)]
    }
    private func custom(_ analysis: WaterAnalysis, _ adjustments: CustomAdjustments, plan: RestorationPlan? = nil) -> ColorCorrection {
        .make(analysis: analysis, preset: .custom, plan: plan, adjustments: adjustments)
    }
    private func solid(_ c: SIMD3<Float>) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), colorSpace: FilterEngine.workingSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    private func pixel(_ image: CIImage, _ engine: FilterEngine) -> SIMD3<Float> {
        var p = [Float](repeating: 0, count: 4)
        engine.context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 1, y: 1, width: 1, height: 1),
                              format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        return SIMD3(p[0], p[1], p[2])
    }
    private func assertEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 { XCTAssertEqual(lhs[channel], rhs[channel], accuracy: accuracy, file: file, line: line) }
    }

    // MARK: Preset

    func testCustomIsLastWithAGearAndNaturalValues() {
        XCTAssertEqual(DivePreset.allCases.last, .custom)
        XCTAssertEqual(DivePreset.allCases, [.original, .natural, .tropical, .deep, .custom])
        XCTAssertEqual(DivePreset.custom.symbolName, "gearshape")
        let c = DivePreset.custom, n = DivePreset.natural
        XCTAssertEqual([c.restoration, c.vibrance, c.castRemoval, c.contrast, c.saturation, c.clarity],
                       [n.restoration, n.vibrance, n.castRemoval, n.contrast, n.saturation, n.clarity])
    }

    func testCustomWithZeroAdjustmentsEqualsNatural() throws {
        for analysis in scenes {
            for plan in try plans() {
                let natural = ColorCorrection.make(analysis: analysis, preset: .natural, plan: plan)
                XCTAssertEqual(ColorCorrection.make(analysis: analysis, preset: .custom, plan: plan), natural)
                XCTAssertEqual(custom(analysis, .zero, plan: plan), natural)
            }
            let uniform = try makePlan(depth: 0.5, confidence: 0.7).sceneLevel()
            XCTAssertEqual(custom(analysis, .zero, plan: uniform), .make(analysis: analysis, preset: .natural, plan: uniform))
        }
    }

    func testCustomRendersAtFullStrength() {
        XCTAssertEqual(FilterSettings(preset: .custom, intensity: 0.3).appliedIntensity, FilterSettings.customStrength)
        XCTAssertEqual(FilterSettings.customStrength, 1)
        for preset in [DivePreset.original, .natural, .tropical, .deep] {
            XCTAssertEqual(FilterSettings(preset: preset, intensity: 0.3).appliedIntensity, 0.3)
        }
        // A low intensity slider value does not weaken Custom; it does weaken Natural.
        let engine = FilterEngine(), image = solid(.init(0.05, 0.3, 0.4)), analysis = scenes[0]
        let customSettings = FilterSettings(preset: .custom, intensity: 0.2, analysis: analysis)
        assertEqual(pixel(engine.apply(image, settings: customSettings), engine),
                    pixel(engine.finishing(image, settings: customSettings), engine), accuracy: 1e-3)
        let naturalSettings = FilterSettings(preset: .natural, intensity: 0.2, analysis: analysis)
        let weak = pixel(engine.apply(image, settings: naturalSettings), engine)
        let full = pixel(engine.finishing(image, settings: naturalSettings), engine)
        XCTAssertGreaterThan(simd_length(weak - full), 0.01)
    }

    func testCombinedUsesFullStrengthForCustom() throws {
        // The depth-aware path blends with appliedIntensity too, so intensity 0.1 and 1 give the same Custom image.
        let engine = FilterEngine(), restoration = RestorationEngine(), image = solid(.init(0.05, 0.3, 0.4))
        let plan = try makePlan(depth: 0.5, confidence: 0.7)
        var settings = FilterSettings(preset: .custom, intensity: 0.1, analysis: scenes[0],
                                      adjustments: .init(brightness: 0.4, saturation: -0.3))
        let low = pixel(try restoration.combined(image, plan: plan, settings: settings, filter: engine), engine)
        settings.intensity = 1
        let high = pixel(try restoration.combined(image, plan: plan, settings: settings, filter: engine), engine)
        assertEqual(low, high, accuracy: 1e-4)
        // And the values combined applies carry the adjustments on both paths.
        let values = restoration.corrections(settings: settings, plan: plan)
        XCTAssertEqual(values.current, custom(scenes[0], settings.adjustments))
        XCTAssertEqual(values.restored, custom(scenes[0], settings.adjustments, plan: plan))
    }

    // MARK: Slider mapping

    func testEachSliderMovesItsTargetValue() throws {
        let analysis = scenes[0]
        for plan in try plans() {
            let base = custom(analysis, .zero, plan: plan)
            XCTAssertLessThan(base.toneCurve, 0.28)             // room for Contrast up
            let darker = custom(analysis, adjust(\.brightness, -1), plan: plan)
            XCTAssertEqual(darker.midLift, max(ColorCorrection.minimumMidLift, base.midLift - 0.25), accuracy: 1e-6)
            XCTAssertEqual(darker.shadowLift, base.shadowLift)
            let brighter = custom(analysis, adjust(\.brightness, 1), plan: plan)
            XCTAssertEqual(brighter.shadowLift, base.shadowLift + 0.075, accuracy: 1e-6)
            XCTAssertEqual(brighter.midLift, base.midLift)
            XCTAssertEqual(custom(analysis, adjust(\.contrast, -1), plan: plan).toneCurve, max(0, base.toneCurve - 0.10), accuracy: 1e-6)
            XCTAssertEqual(custom(analysis, adjust(\.contrast, 1), plan: plan).toneCurve, base.toneCurve + 0.02, accuracy: 1e-6)
            XCTAssertEqual(custom(analysis, adjust(\.saturation, -1), plan: plan).saturation, base.saturation - CustomAdjustments.Caps.saturationDown, accuracy: 1e-6)
            XCTAssertGreaterThan(custom(analysis, adjust(\.saturation, 1), plan: plan).saturation, base.saturation + 0.01)
            let soft = custom(analysis, adjust(\.clarity, -1), plan: plan), sharp = custom(analysis, adjust(\.clarity, 1), plan: plan)
            XCTAssertEqual(soft.clarity, 0); XCTAssertEqual(soft.definition, 0)
            XCTAssertEqual(sharp.clarity, base.clarity * 1.75, accuracy: 1e-6)
            XCTAssertEqual(sharp.definition, base.definition * 1.75, accuracy: 1e-6)
            let kelvin = CustomAdjustments.Caps.temperature
            XCTAssertEqual(custom(analysis, adjust(\.temperature, -1), plan: plan).warmth, base.warmth - kelvin, accuracy: 1e-3)
            XCTAssertEqual(custom(analysis, adjust(\.temperature, 1), plan: plan).warmth, base.warmth + kelvin, accuracy: 1e-3)
            // Half a slider moves half as far.
            XCTAssertEqual(custom(analysis, adjust(\.temperature, 0.5), plan: plan).warmth, base.warmth + kelvin / 2, accuracy: 1e-3)
        }
    }

    func testNeonWaterGetsASmallerSaturationRaise() {
        let neon = scene(water: .init(0.001, 0.02, 0.4)), blue = scenes[0]
        let neonRaise = custom(neon, adjust(\.saturation, 1)).saturation - custom(neon, .zero).saturation
        let blueRaise = custom(blue, adjust(\.saturation, 1)).saturation - custom(blue, .zero).saturation
        XCTAssertGreaterThan(neonRaise, 0)
        XCTAssertLessThanOrEqual(neonRaise, CustomAdjustments.Caps.saturationUp * 0.4 + 1e-6)
        XCTAssertLessThan(neonRaise, blueRaise)
        XCTAssertLessThan(custom(neon, adjust(\.saturation, -1)).saturation, custom(neon, .zero).saturation)
    }

    func testSaturationReachesTheWaterButNeverMakesItNeon() throws {
        // Finished water chroma, approximated as the kernel's water chroma times CIColorControls saturation.
        func finalChroma(_ analysis: WaterAnalysis, _ values: ColorCorrection) -> Float {
            ColorCorrection.oklch(FinishingMath.color(analysis.waterColor, correction: values)).y * values.saturation
        }
        for (index, analysis) in scenes.prefix(5).enumerated() {
            for plan in try plans() {
                let base = finalChroma(analysis, custom(analysis, .zero, plan: plan))
                let raised = finalChroma(analysis, custom(analysis, adjust(\.saturation, 1), plan: plan))
                let cut = finalChroma(analysis, custom(analysis, adjust(\.saturation, -1), plan: plan))
                XCTAssertGreaterThan(raised, base * 1.05, "scene \(index): the water must show the raise")
                XCTAssertLessThanOrEqual(raised, base * 1.35, "scene \(index): no neon water")
                XCTAssertLessThan(cut, base * 0.95, "scene \(index): the water must show the cut")
                XCTAssertGreaterThan(cut, base * 0.45, "scene \(index): the water must not turn grey")
            }
        }
    }

    func testTemperatureWarmsAndCoolsGreyWithoutIndigo() {
        // Through the real CITemperatureAndTint filter. A cool shift has no magenta tint, so grey stays blue.
        let engine = FilterEngine()
        for position: Float in [1, 0.5, -0.5, -1] {
            var values = ColorCorrection.identity
            values.warmth = position * CustomAdjustments.Caps.temperature
            let out = ColorCorrection.oklch(pixel(engine.finishing(solid(.init(repeating: 0.35)), correction: values), engine))
            XCTAssertGreaterThan(out.y, abs(position) * 0.02, "position \(position): the tint must be visible")
            if position > 0 { XCTAssertTrue((70...130).contains(out.z), "position \(position): warm grey should be yellow, hue \(out.z)") }
            else { XCTAssertTrue((225...265).contains(out.z), "position \(position): cool grey should be blue, hue \(out.z)") }
        }
    }

    func testPositionsAreClampedToPlusMinusOne() throws {
        for plan in try plans() {
            for key in sliders {
                XCTAssertEqual(custom(scenes[0], adjust(key, 5), plan: plan), custom(scenes[0], adjust(key, 1), plan: plan))
                XCTAssertEqual(custom(scenes[0], adjust(key, -5), plan: plan), custom(scenes[0], adjust(key, -1), plan: plan))
                XCTAssertEqual(custom(scenes[0], adjust(key, .nan), plan: plan), custom(scenes[0], .zero, plan: plan))
                XCTAssertEqual(custom(scenes[0], adjust(key, .infinity), plan: plan), custom(scenes[0], .zero, plan: plan))
            }
        }
        XCTAssertEqual(CustomAdjustments(brightness: 3, contrast: -3, saturation: .nan, clarity: 0.4, temperature: -.infinity).clamped,
                       CustomAdjustments(brightness: 1, contrast: -1, saturation: 0, clarity: 0.4, temperature: 0))
    }

    func testJointBudgetScalesPositiveBrightnessContrastSaturation() {
        let all = CustomAdjustments(brightness: 1, contrast: 1, saturation: 1).budgeted
        XCTAssertEqual(all.brightness, 1 / 3, accuracy: 1e-6)
        XCTAssertEqual(all.contrast, 1 / 3, accuracy: 1e-6)
        XCTAssertEqual(all.saturation, 1 / 3, accuracy: 1e-6)
        // At or below the budget nothing changes. Negative parts, clarity and temperature never scale.
        let within = CustomAdjustments(brightness: 0.5, contrast: 0.5, saturation: -1, clarity: 1, temperature: 1)
        XCTAssertEqual(within.budgeted, within)
        let over = CustomAdjustments(brightness: 0.8, contrast: -0.5, saturation: 0.6, clarity: 1, temperature: -1).budgeted
        XCTAssertEqual(over.brightness, 0.8 / 1.4, accuracy: 1e-6)
        XCTAssertEqual(over.saturation, 0.6 / 1.4, accuracy: 1e-6)
        XCTAssertEqual(over.contrast, -0.5); XCTAssertEqual(over.clarity, 1); XCTAssertEqual(over.temperature, -1)
        // make() applies the budget.
        let third: Float = 1 / 3
        XCTAssertEqual(custom(scenes[0], .init(brightness: 1, contrast: 1, saturation: 1)),
                       custom(scenes[0], .init(brightness: third, contrast: third, saturation: third)))
    }

    // MARK: Guards

    func testGuardValuesDoNotChangeWithAnyAdjustment() throws {
        // These guards never read an adjusted value.
        let fixed: [(String, KeyPath<ColorCorrection, Float>)] = [
            ("violetGuard", \.violetGuard), ("redCeiling", \.redCeiling), ("waterChroma", \.waterChroma),
            ("waterRedness", \.waterRedness), ("waterType", \.waterType)]
        // These come from the toned water. Saturation enters before the water chroma ceiling (so neon
        // calming still applies), so it moves the toned water and with it these values. No other slider does.
        let toned: [(String, KeyPath<ColorCorrection, Float>)] = [
            ("redGateLow", \.redGateLow), ("redGateHigh", \.redGateHigh), ("subjectRed", \.subjectRed)]
        for (index, analysis) in scenes.enumerated() {
            for plan in try plans() {
                let base = custom(analysis, .zero, plan: plan)
                for adjustments in extremes {
                    let values = custom(analysis, adjustments, plan: plan)
                    for (name, key) in fixed + (adjustments.saturation == 0 ? toned : []) {
                        XCTAssertEqual(values[keyPath: key], base[keyPath: key], accuracy: 1e-6,
                                       "\(name) moved: scene \(index), plan \(plan != nil), \(adjustments)")
                    }
                }
            }
        }
    }

    func testUserSaturationLeavesTheWaterToneUnchanged() throws {
        // The water chroma ceiling ignores the user's saturation, so the water colour before the
        // saturation step is the same; the step itself then shows on the water.
        for (index, analysis) in scenes.prefix(5).enumerated() {
            for plan in try plans() {
                let base = custom(analysis, .zero, plan: plan), raised = custom(analysis, adjust(\.saturation, 1), plan: plan)
                let water = analysis.waterColor
                XCTAssertLessThanOrEqual(ColorCorrection.oklch(FinishingMath.color(water, correction: raised)).y,
                                         ColorCorrection.oklch(FinishingMath.color(water, correction: base)).y + 1e-4,
                                         "scene \(index), plan \(plan != nil)")
            }
        }
    }

    func testNeutralRampStaysNeutralAtEverySliderExtreme() throws {
        // Temperature tints greys on purpose, so it stays at zero here.
        let grey = greyScene(), uniform = try makePlan(depth: 0.5, confidence: 0.7).sceneLevel()
        let cases = extremes.map { a -> CustomAdjustments in var a = a; a.temperature = 0; return a }
        for adjustments in cases {
            for plan in try plans() + [uniform] {
                let values = custom(grey, adjustments, plan: plan)
                for level: Float in [0.05, 0.2, 0.5, 0.8] {
                    let out = FinishingMath.color(.init(repeating: level), correction: values)
                    XCTAssertEqual(ColorCorrection.lightnessChromaHue(out).y, 0, accuracy: 1, "\(adjustments) level \(level)")
                }
            }
        }
    }

    func testWhiteReferenceSurfaceStaysNeutralAtEverySliderExtreme() throws {
        // A scene whose white reference is active: its sand must stay near grey whatever the sliders do.
        // Temperature tints greys on purpose, so it stays at zero here.
        // The restored path acts at some depths only, as in RestorationTests, so it needs one active depth.
        let sand = sandScene()
        XCTAssertNotEqual(custom(sand, .zero).neutralGains, .one, "the white reference must be active on the current path")
        var restoredActive = false
        for depth: Float? in [nil, 0.1, 0.5] {
            let plan = try depth.map { try makePlan(depth: $0, confidence: 0.7) }
            guard custom(sand, .zero, plan: plan).neutralGains != .one else { continue }
            if plan != nil { restoredActive = true }
            let seen = plan.map { p in RestorationMath.inverse(observed: sand.neutralColor, depth: depth ?? 0.5,
                backscatterInfinity: p.backscatterInfinity, betaDirect: p.betaDirect, betaBackscatter: p.betaBackscatter,
                limits: p.limits, recoverability: p.channelRecoverability).color } ?? sand.neutralColor
            let base = ColorCorrection.lightnessChromaHue(FinishingMath.color(seen, correction: custom(sand, .zero, plan: plan))).y
            for var adjustments in extremes {
                adjustments.temperature = 0
                let out = FinishingMath.color(seen, correction: custom(sand, adjustments, plan: plan))
                XCTAssertLessThanOrEqual(ColorCorrection.lightnessChromaHue(out).y, base + 1.5, "\(adjustments) depth \(String(describing: depth))")
            }
        }
        XCTAssertTrue(restoredActive, "the white reference must be active at one restored depth")
    }

    func testBrightnessDownDarkensAndKeepsBlackWhiteAndOrder() {
        var values = ColorCorrection.identity
        values.castGains = .init(1.0001, 1, 1)
        values.midLift = ColorCorrection.minimumMidLift; values.toneCurve = 0.2; values.tonePivot = 0.4
        XCTAssertEqual(FinishingMath.color(.zero, correction: values), .zero)
        var previous: Float = 0
        for step in 1...99 {
            let level = Float(step) / 100
            let out = FinishingMath.color(.init(repeating: level), correction: values)
            XCTAssertGreaterThanOrEqual(out.y, previous)
            previous = out.y
        }
        var plain = values; plain.midLift = 0
        XCTAssertLessThan(FinishingMath.color(.init(repeating: 0.2), correction: values).y,
                          FinishingMath.color(.init(repeating: 0.2), correction: plain).y)
    }

    func testFinishingKernelMatchesCPUMirrorWithNegativeMidLift() {
        let engine = FilterEngine()
        for lift: Float in [ColorCorrection.minimumMidLift, -0.1] {
            var values = ColorCorrection.identity
            values.castGains = .init(1.3, 0.85, 1.2); values.redRebuild = 0.25; values.subjectRed = 0.4
            values.midLift = lift; values.toneCurve = 0.2; values.tonePivot = 0.42
            values.waterTone = .init(0.8, 1.15, 0.7); values.waterRedness = 0.12
            values.waterSaturation = 0.6; values.waterChroma = 0.8; values.violetGuard = 0.7
            for color: SIMD3<Float> in [.init(0.05, 0.3, 0.35), .init(0.3, 0.25, 0.2), .init(0.2, 0.2, 0.2),
                                        .init(0.02, 0.15, 0.4), .init(0.6, 0.6, 0.6), .init(0.01, 0.03, 0.05)] {
                // finishing ends with the highlight shoulder.
                let expected = FinishingMath.shoulder(FinishingMath.color(color, correction: values), reference: color)
                assertEqual(pixel(engine.finishing(solid(color), correction: values), engine), expected,
                            accuracy: 0.004 * max(1, expected.max()))
            }
        }
    }

    func testOriginalAndBuiltInPresetsIgnoreAdjustments() throws {
        for preset in [DivePreset.original, .natural, .tropical, .deep] {
            for analysis in scenes {
                for plan in try plans() {
                    let plain = ColorCorrection.make(analysis: analysis, preset: preset, plan: plan)
                    for adjustments in extremes {
                        XCTAssertEqual(ColorCorrection.make(analysis: analysis, preset: preset, plan: plan, adjustments: adjustments), plain)
                    }
                }
            }
        }
        // The engine's settings path too.
        let engine = FilterEngine(), image = solid(.init(0.05, 0.3, 0.4))
        var settings = FilterSettings(preset: .deep, intensity: 0.7, analysis: scenes[0])
        let before = pixel(engine.apply(image, settings: settings), engine)
        settings.adjustments = .init(brightness: 1, contrast: 1, saturation: 1, clarity: 1, temperature: 1)
        assertEqual(pixel(engine.apply(image, settings: settings), engine), before, accuracy: 0)
    }

    // MARK: Store

    private func freshDefaults() -> (UserDefaults, String) {
        let name = "CustomPresetTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testStoreRoundTripAndMissingData() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CustomAdjustmentsStore(defaults: defaults)
        XCTAssertEqual(store.load(), .zero)
        let value = CustomAdjustments(brightness: -0.3, contrast: 0.25, saturation: 1, clarity: -1, temperature: 0.07)
        store.save(value)
        XCTAssertEqual(store.load(), value)
        XCTAssertEqual(CustomAdjustmentsStore(defaults: defaults).load(), value)
        // Saved as versioned JSON under the agreed key, with no preset name.
        let json = try? JSONSerialization.jsonObject(with: defaults.data(forKey: "customAdjustments.v1") ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["version", "brightness", "contrast", "saturation", "clarity", "temperature"])
    }

    func testStoreTreatsBrokenOutOfRangeAndNonFiniteDataSafely() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CustomAdjustmentsStore(defaults: defaults)
        func stored(_ text: String) -> CustomAdjustments {
            defaults.set(Data(text.utf8), forKey: CustomAdjustmentsStore.key); return store.load()
        }
        XCTAssertEqual(stored("not json"), .zero)
        XCTAssertEqual(stored("{\"version\":1,\"brightness\":\"high\"}"), .zero)
        XCTAssertEqual(stored("{\"version\":2,\"brightness\":0.5}"), .zero)          // unknown version
        XCTAssertEqual(stored("{\"brightness\":0.5}"), .zero)                        // no version
        XCTAssertEqual(stored("{\"version\":1,\"contrast\":0.4}"), .init(contrast: 0.4))  // missing fields are zero
        XCTAssertEqual(stored("{\"version\":1,\"brightness\":7,\"contrast\":-3,\"saturation\":0.2,\"clarity\":1,\"temperature\":-1}"),
                       .init(brightness: 1, contrast: -1, saturation: 0.2, clarity: 1, temperature: -1))
        XCTAssertEqual(stored("{\"version\":1,\"brightness\":\"nan\",\"contrast\":\"inf\",\"saturation\":\"-inf\",\"clarity\":0.5,\"temperature\":1e60}"),
                       .init(clarity: 0.5, temperature: 0))
        // Saving non-finite or out-of-range values stores clamped, finite ones.
        store.save(.init(brightness: .nan, contrast: 9, saturation: -.infinity))
        XCTAssertEqual(store.load(), .init(contrast: 1))
        defaults.set("a string", forKey: CustomAdjustmentsStore.key)
        XCTAssertEqual(store.load(), .zero)
    }

    // MARK: Models

    @MainActor
    func testBatchSettingsCarryTheSavedAdjustmentsForCustomOnly() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CustomAdjustmentsStore(defaults: defaults)
        let saved = CustomAdjustments(brightness: 0.2, contrast: -0.4, saturation: 0.1, clarity: 0.3, temperature: -0.6)
        store.save(saved)
        let model = BatchModel(urls: [URL(fileURLWithPath: "/tmp/a.heic"), URL(fileURLWithPath: "/tmp/b.heic")],
                               diagnostics: DiagnosticRecorder(directory: FileManager.default.temporaryDirectory),
                               adjustmentStore: store)
        XCTAssertEqual(model.adjustments, saved)
        model.shared.preset = .custom
        XCTAssertEqual(model.settings(for: model.items[0]).adjustments, saved)
        XCTAssertEqual(model.settings(for: model.items[0]).appliedIntensity, 1)
        // A photo overridden to a built-in preset gets no adjustments; one overridden to Custom gets the saved ones.
        model.setOverride(.init(preset: .tropical, intensity: 0.5), for: model.items[1].id)
        XCTAssertEqual(model.settings(for: model.items[1]).adjustments, .zero)
        model.shared.preset = .natural
        XCTAssertEqual(model.settings(for: model.items[0]).adjustments, .zero)
        model.setOverride(.init(preset: .custom, intensity: 0.5), for: model.items[1].id)
        XCTAssertEqual(model.settings(for: model.items[1]).adjustments, saved)
        // Custom renders at full strength, so Custom with another intensity is the shared look, not an override.
        model.shared = .init(preset: .custom, intensity: 0.8)
        model.setOverride(.init(preset: .custom, intensity: 0.5), for: model.items[1].id)
        XCTAssertNil(model.items[1].override)
        // Changes are written back to the one slot.
        model.adjustments.saturation = -1
        XCTAssertEqual(store.load().saturation, -1)
    }

    @MainActor
    func testEditorLoadsAndSavesTheAdjustments() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CustomAdjustmentsStore(defaults: defaults)
        store.save(.init(temperature: 0.5))
        let model = EditorModel(media: ImportedMedia(url: URL(fileURLWithPath: "/tmp/none.heic"), kind: .photo),
                                diagnostics: DiagnosticRecorder(directory: FileManager.default.temporaryDirectory),
                                adjustmentStore: store)
        XCTAssertEqual(model.settings.adjustments, .init(temperature: 0.5))
        model.settings.adjustments.brightness = -0.2
        XCTAssertEqual(store.load(), .init(brightness: -0.2, temperature: 0.5))
        model.settings.adjustments = .zero
        XCTAssertEqual(store.load(), .zero)
    }

    func testSliderValueText() {
        XCTAssertEqual(CustomAdjustmentControls.valueText(0.3), "+30")
        XCTAssertEqual(CustomAdjustmentControls.valueText(-1), "-100")
        XCTAssertEqual(CustomAdjustmentControls.valueText(0.0001), "0")
        XCTAssertEqual(CustomAdjustmentControls.valueText(-0.001), "0")
        XCTAssertEqual(CustomAdjustmentControls.valueText(.nan), "0")
    }
}
