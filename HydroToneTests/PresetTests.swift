import XCTest
import CoreImage
@testable import HydroTone

/// Preset looks. Natural Dive is the automatic result and the base for user presets, so its values
/// are pinned. Tropical and Deep Dive are checked against Natural Dive on the same scene.
final class PresetTests: XCTestCase {
    let engine = FilterEngine()

    /// Natural Dive values from the rules at commit a439df0, on fixed analyses, without a plan, with a
    /// per-pixel plan and with its constant-depth (video) version. Any change to them is a product change.
    static let pinnedNatural: [String] = [
        "blue|source|castGains=SIMD3<Float>(1.3184863, 0.9797542, 0.9797542);redRebuild=0.49650913;redGateLow=0.7885417;redGateHigh=1.1885417;subjectRed=0.59973073;waterTone=SIMD3<Float>(1.2657892, 1.0175126, 0.7492867);waterRedness=0.03364329;waterSaturation=0.5886914;waterChroma=0.95514226;waterType=0.04583329;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.25999993;tonePivot=0.3814574;brightness=0.009;contrast=1.0649999;saturation=0.8960206;shadowLift=0.39;highlightAmount=0.92;clarity=0.1584;clarityRadius=0.013541667;definition=0.144;definitionRadius=0.04;warmth=0.0;vibrance=0.004613936;physicalWeight=0.0;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.026369726, 0.19595085, 0.58785254)",
        "blue|plan|castGains=SIMD3<Float>(1.3184863, 0.9797542, 0.9797542);redRebuild=0.49650913;redGateLow=0.7885417;redGateHigh=1.1885417;subjectRed=0.47199827;waterTone=SIMD3<Float>(1.3014481, 1.0125378, 0.7516347);waterRedness=0.03364329;waterSaturation=0.5340412;waterChroma=0.95514226;waterType=0.04583329;redCeiling=1.05;violetGuard=1.0;midLift=0.117236994;toneCurve=0.25999993;tonePivot=0.3814574;brightness=0.009;contrast=1.0649999;saturation=0.8960206;shadowLift=0.39;highlightAmount=0.92;clarity=0.1584;clarityRadius=0.013541667;definition=0.144;definitionRadius=0.04;warmth=0.0;vibrance=0.004613936;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0, 0.20438756, 0.6181121)",
        "blue|uniform|castGains=SIMD3<Float>(1.3184863, 0.9797542, 0.9797542);redRebuild=0.49650913;redGateLow=0.7885417;redGateHigh=1.1885417;subjectRed=0.47211805;waterTone=SIMD3<Float>(1.3011513, 1.0126575, 0.7512033);waterRedness=0.03364329;waterSaturation=0.5337451;waterChroma=0.95514226;waterType=0.04583329;redCeiling=1.05;violetGuard=1.0;midLift=0.114631936;toneCurve=0.25999993;tonePivot=0.3814574;brightness=0.009;contrast=1.0649999;saturation=0.8960206;shadowLift=0.39;highlightAmount=0.92;clarity=0.1584;clarityRadius=0.013541667;definition=0.144;definitionRadius=0.04;warmth=0.0;vibrance=0.004613936;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0, 0.20522778, 0.6211627)",
        "neon|source|castGains=SIMD3<Float>(1.3083414, 0.9674201, 0.9674201);redRebuild=0.51685715;redGateLow=0.62377375;redGateHigh=1.0237738;subjectRed=0.5724355;waterTone=SIMD3<Float>(1.0717719, 1.3301276, 0.45);waterRedness=0.018032033;waterSaturation=0.5400024;waterChroma=0.98068;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.2814285;tonePivot=0.3;brightness=0.009;contrast=1.0739285;saturation=0.88;shadowLift=0.4292857;highlightAmount=0.92;clarity=0.1704;clarityRadius=0.014657738;definition=0.16685714;definitionRadius=0.04;warmth=0.0;vibrance=0.0;physicalWeight=0.0;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.013083413, 0.048371006, 0.67719406)",
        "neon|plan|castGains=SIMD3<Float>(1.3083414, 0.9674201, 0.9674201);redRebuild=0.51685715;redGateLow=0.628216;redGateHigh=1.028216;subjectRed=0.7902703;waterTone=SIMD3<Float>(0.95120543, 1.3633907, 0.45);waterRedness=0.018032033;waterSaturation=0.35000002;waterChroma=0.98068;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.44776073;toneCurve=0.2814285;tonePivot=0.3;brightness=0.009;contrast=1.0739285;saturation=0.88;shadowLift=0.4292857;highlightAmount=0.92;clarity=0.1704;clarityRadius=0.014657738;definition=0.16685714;definitionRadius=0.04;warmth=0.0;vibrance=0.0;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0, 0.01595095, 0.72133255)",
        "neon|uniform|castGains=SIMD3<Float>(1.3083414, 0.9674201, 0.9674201);redRebuild=0.51685715;redGateLow=0.5999176;redGateHigh=0.9999176;subjectRed=0.7972367;waterTone=SIMD3<Float>(0.96149004, 1.378132, 0.45);waterRedness=0.018032033;waterSaturation=0.35000002;waterChroma=0.98068;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.4658031;toneCurve=0.2814285;tonePivot=0.3;brightness=0.009;contrast=1.0739285;saturation=0.88;shadowLift=0.4292857;highlightAmount=0.92;clarity=0.1704;clarityRadius=0.014657738;definition=0.16685714;definitionRadius=0.04;warmth=0.0;vibrance=0.0;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0, 0.012551267, 0.725741)",
        "teal|source|castGains=SIMD3<Float>(1.4154601, 0.9641136, 1.1675459);redRebuild=0.46074075;redGateLow=0.55;redGateHigh=0.95000005;subjectRed=0.6642878;waterTone=SIMD3<Float>(1.5109986, 0.9105328, 1.2577814);waterRedness=0.051203594;waterSaturation=0.62936026;waterChroma=0.9042891;waterType=1.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.25999993;tonePivot=0.42217845;brightness=0.009;contrast=1.0649999;saturation=0.8998426;shadowLift=0.39;highlightAmount=0.92;clarity=0.1584;clarityRadius=0.013541667;definition=0.144;definitionRadius=0.04;warmth=0.0;vibrance=0.0057146586;physicalWeight=0.0;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0424638, 0.38564545, 0.44366744)",
        "teal|plan|castGains=SIMD3<Float>(1.4154601, 0.9641136, 1.1675459);redRebuild=0.46074075;redGateLow=0.55;redGateHigh=0.95000005;subjectRed=0.46007246;waterTone=SIMD3<Float>(1.591437, 0.8973408, 1.3568662);waterRedness=0.051203594;waterSaturation=0.5964645;waterChroma=0.9042891;waterType=1.0;redCeiling=1.05;violetGuard=1.0;midLift=0.034824207;toneCurve=0.25999993;tonePivot=0.42217845;brightness=0.009;contrast=1.0649999;saturation=0.8998426;shadowLift=0.39;highlightAmount=0.92;clarity=0.1584;clarityRadius=0.013541667;definition=0.144;definitionRadius=0.04;warmth=0.0;vibrance=0.0057146586;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.02117133, 0.4480958, 0.44186524)",
        "teal|uniform|castGains=SIMD3<Float>(1.4154601, 0.9641136, 1.1675459);redRebuild=0.46074075;redGateLow=0.55;redGateHigh=0.95000005;subjectRed=0.46056458;waterTone=SIMD3<Float>(1.6007367, 0.8961241, 1.365741);waterRedness=0.051203594;waterSaturation=0.59181523;waterChroma=0.9042891;waterType=1.0;redCeiling=1.05;violetGuard=1.0;midLift=0.024930133;toneCurve=0.25999993;tonePivot=0.42217845;brightness=0.009;contrast=1.0649999;saturation=0.8998426;shadowLift=0.39;highlightAmount=0.92;clarity=0.1584;clarityRadius=0.013541667;definition=0.144;definitionRadius=0.04;warmth=0.0;vibrance=0.0057146586;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.01754878, 0.45454246, 0.44179344)",
        "bright|source|castGains=SIMD3<Float>(1.3046706, 0.9810694, 0.9810694);redRebuild=0.4022763;redGateLow=0.6426536;redGateHigh=1.0426536;subjectRed=0.65895003;waterTone=SIMD3<Float>(1.3745289, 0.9549473, 0.96035695);waterRedness=0.069991864;waterSaturation=0.64031667;waterChroma=0.8891795;waterType=0.6293858;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.1666666;tonePivot=0.57853264;brightness=0.009;contrast=1.04;saturation=0.93256825;shadowLift=0.31333333;highlightAmount=0.92;clarity=0.1248;clarityRadius=0.010416667;definition=0.08;definitionRadius=0.04;warmth=0.0;vibrance=0.018924559;physicalWeight=0.0;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.06523353, 0.34337428, 0.58864164)",
        "bright|plan|castGains=SIMD3<Float>(1.3046706, 0.9810694, 0.9810694);redRebuild=0.4022763;redGateLow=0.6426536;redGateHigh=1.0426536;subjectRed=0.49677217;waterTone=SIMD3<Float>(1.4191521, 0.9439423, 1.0037783);waterRedness=0.069991864;waterSaturation=0.62475485;waterChroma=0.8891795;waterType=0.6293858;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.1666666;tonePivot=0.57853264;brightness=0.009;contrast=1.04;saturation=0.93256825;shadowLift=0.31333333;highlightAmount=0.92;clarity=0.1248;clarityRadius=0.010416667;definition=0.08;definitionRadius=0.04;warmth=0.0;vibrance=0.018924559;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.062320426, 0.3931478, 0.6189418)",
        "bright|uniform|castGains=SIMD3<Float>(1.3046706, 0.9810694, 0.9810694);redRebuild=0.4022763;redGateLow=0.6426536;redGateHigh=1.0426536;subjectRed=0.49721122;waterTone=SIMD3<Float>(1.4279985, 0.94244003, 1.0088594);waterRedness=0.069991864;waterSaturation=0.6195637;waterChroma=0.8891795;waterType=0.6293858;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.1666666;tonePivot=0.57853264;brightness=0.009;contrast=1.04;saturation=0.93256825;shadowLift=0.31333333;highlightAmount=0.92;clarity=0.1248;clarityRadius=0.010416667;definition=0.08;definitionRadius=0.04;warmth=0.0;vibrance=0.018924559;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.05922935, 0.39827815, 0.6219965)",
        "sand|source|castGains=SIMD3<Float>(1.3383317, 0.98406744, 0.98406744);redRebuild=0.49978325;redGateLow=0.77060753;redGateHigh=1.1706076;subjectRed=0.59291637;waterTone=SIMD3<Float>(1.3047872, 1.0064418, 0.7690131);waterRedness=0.015454546;waterSaturation=0.5594347;waterChroma=0.9790769;waterType=0.117569864;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.21714279;tonePivot=0.48115653;brightness=0.0045;contrast=1.0471429;saturation=0.88;shadowLift=0.29257143;highlightAmount=0.92;clarity=0.1344;clarityRadius=0.011309523;definition=0.09828571;definitionRadius=0.04;warmth=0.0;vibrance=0.0;physicalWeight=0.0;neutralGains=SIMD3<Float>(1.1483217, 0.98658574, 0.86878455);waterLit=SIMD3<Float>(0.013383317, 0.22633551, 0.6396438)",
        "sand|plan|castGains=SIMD3<Float>(1.3383317, 0.98406744, 0.98406744);redRebuild=0.49978325;redGateLow=0.77060753;redGateHigh=1.1706076;subjectRed=0.4305205;waterTone=SIMD3<Float>(1.3174012, 1.0019269, 0.77833116);waterRedness=0.015454546;waterSaturation=0.5303281;waterChroma=0.9790769;waterType=0.117569864;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.21714279;tonePivot=0.48115653;brightness=0.0045;contrast=1.0471429;saturation=0.88;shadowLift=0.29257143;highlightAmount=0.92;clarity=0.1344;clarityRadius=0.011309523;definition=0.09828571;definitionRadius=0.04;warmth=0.0;vibrance=0.0;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0, 0.24309973, 0.67728925)",
        "sand|uniform|castGains=SIMD3<Float>(1.3383317, 0.98406744, 0.98406744);redRebuild=0.49978325;redGateLow=0.77060753;redGateHigh=1.1706076;subjectRed=0.43063554;waterTone=SIMD3<Float>(1.3174667, 1.0018249, 0.778488);waterRedness=0.015454546;waterSaturation=0.53014225;waterChroma=0.9790769;waterType=0.117569864;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.21714279;tonePivot=0.48115653;brightness=0.0045;contrast=1.0471429;saturation=0.88;shadowLift=0.29257143;highlightAmount=0.92;clarity=0.1344;clarityRadius=0.011309523;definition=0.09828571;definitionRadius=0.04;warmth=0.0;vibrance=0.0;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.0, 0.24480407, 0.6810634)",
        "grey|source|castGains=SIMD3<Float>(1.0, 1.0, 1.0);redRebuild=0.0;redGateLow=0.8;redGateHigh=1.2;subjectRed=1.0;waterTone=SIMD3<Float>(1.0, 1.0, 1.0);waterRedness=0.5;waterSaturation=1.0;waterChroma=0.0;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.19999993;tonePivot=0.48115653;brightness=0.0;contrast=1.04;saturation=1.08;shadowLift=0.28;highlightAmount=0.92;clarity=0.1248;clarityRadius=0.010416667;definition=0.08;definitionRadius=0.04;warmth=0.0;vibrance=0.18;physicalWeight=0.0;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.1, 0.1, 0.1)",
        "grey|plan|castGains=SIMD3<Float>(1.0, 1.0, 1.0);redRebuild=0.0;redGateLow=0.8;redGateHigh=1.2;subjectRed=1.3058707;waterTone=SIMD3<Float>(1.0, 1.0, 1.0);waterRedness=0.942482;waterSaturation=1.0;waterChroma=0.0;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.19999993;tonePivot=0.48115653;brightness=0.0;contrast=1.04;saturation=1.08;shadowLift=0.28;highlightAmount=0.92;clarity=0.1248;clarityRadius=0.010416667;definition=0.08;definitionRadius=0.04;warmth=0.0;vibrance=0.18;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.12979208, 0.0805291, 0.057183955)",
        "grey|uniform|castGains=SIMD3<Float>(1.0, 1.0, 1.0);redRebuild=0.0;redGateLow=0.8;redGateHigh=1.2;subjectRed=1.3149253;waterTone=SIMD3<Float>(1.0, 1.0, 1.0);waterRedness=0.9722121;waterSaturation=1.0;waterChroma=0.0;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.19999993;tonePivot=0.48115653;brightness=0.0;contrast=1.04;saturation=1.08;shadowLift=0.28;highlightAmount=0.92;clarity=0.1248;clarityRadius=0.010416667;definition=0.08;definitionRadius=0.04;warmth=0.0;vibrance=0.18;physicalWeight=0.7;neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);waterLit=SIMD3<Float>(0.12789793, 0.07847218, 0.053081356)"
    ]

    func testNaturalDiveValuesAreUnchanged() throws {
        XCTAssertEqual(DivePreset.natural.warmth, 0)
        XCTAssertEqual(DivePreset.natural.waterChroma, 1)
        XCTAssertEqual(DivePreset.natural.shadowBoost, 0)
        let values = try PresetFixtures.naturalValues()
        XCTAssertEqual(values.count, Self.pinnedNatural.count)
        for (value, pinned) in zip(values, Self.pinnedNatural) { XCTAssertEqual(value, pinned) }
    }

    private func image(_ background: SIMD3<Float>, patch: SIMD3<Float>) -> CIImage {
        func solid(_ c: SIMD3<Float>) -> CIImage {
            CIImage(color: CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), colorSpace: FilterEngine.workingSpace)!)
        }
        return solid(patch).cropped(to: CGRect(x: 16, y: 16, width: 32, height: 32))
            .composited(over: solid(background).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
    }
    private func pixel(_ image: CIImage, x: Int, y: Int) -> SIMD3<Float> {
        var m = [Float](repeating: 0, count: 4)
        engine.context.render(image, toBitmap: &m, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                              format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        return SIMD3(m[0], m[1], m[2])
    }
    private func render(_ source: CIImage, _ preset: DivePreset) -> CIImage {
        engine.apply(source, settings: .init(preset: preset, intensity: 0.8, analysis: engine.analyze(source)))
    }

    func testTropicalMakesASubjectWarmerThanNatural() {
        // Sunlit sand or coral in shallow blue water, and the water itself.
        let source = image(.init(0.03, 0.22, 0.55), patch: .init(0.22, 0.30, 0.30))
        let natural = render(source, .natural), tropical = render(source, .tropical)
        let n = pixel(natural, x: 32, y: 32), t = pixel(tropical, x: 32, y: 32)
        XCTAssertGreaterThan(ColorCorrection.lab(t).z, ColorCorrection.lab(n).z + 1, "Tropical subject b* must be clearly warmer")
        XCTAssertGreaterThanOrEqual(t.x / t.y, n.x / n.y, "Tropical subject red/green")
        // The water stays cyan to blue: OKLab hue 215 to 265, and no more colourful than Natural's by 10%.
        let nw = ColorCorrection.oklch(pixel(natural, x: 4, y: 4)), tw = ColorCorrection.oklch(pixel(tropical, x: 4, y: 4))
        XCTAssertGreaterThan(tw.z, 215); XCTAssertLessThan(tw.z, 265)
        XCTAssertLessThanOrEqual(tw.y, nw.y * 1.1)
    }

    func testDeepDiveLiftsADarkSceneAndCalmsNeonWater() throws {
        // A dark, deep blue scene: neon water and a dim blue-green subject.
        let source = image(.init(0.005, 0.03, 0.30), patch: .init(0.02, 0.06, 0.12))
        let analysis = engine.analyze(source)
        XCTAssertLessThan(analysis.midLuminance, 0.1)
        let plan = try PresetFixtures.plan()
        for p in [nil, plan, try plan.sceneLevel()] as [RestorationPlan?] {
            let n = ColorCorrection.make(analysis: analysis, preset: .natural, plan: p)
            let d = ColorCorrection.make(analysis: analysis, preset: .deep, plan: p)
            XCTAssertGreaterThan(d.shadowLift, n.shadowLift)
            XCTAssertGreaterThanOrEqual(d.redRebuild, n.redRebuild)
        }
        let natural = render(source, .natural), deep = render(source, .deep)
        func luminance(_ c: SIMD3<Float>) -> Float { (c * SIMD3(0.2627, 0.6780, 0.0593)).sum() }
        let nSubject = pixel(natural, x: 32, y: 32), dSubject = pixel(deep, x: 32, y: 32)
        XCTAssertGreaterThanOrEqual(luminance(dSubject), luminance(nSubject), "Deep Dive lifts the dark subject")
        XCTAssertGreaterThanOrEqual(luminance(pixel(deep, x: 4, y: 4)), luminance(pixel(natural, x: 4, y: 4)))
        let nw = ColorCorrection.oklch(pixel(natural, x: 4, y: 4)), dw = ColorCorrection.oklch(pixel(deep, x: 4, y: 4))
        XCTAssertLessThanOrEqual(dw.y, nw.y + 1e-4, "Deep Dive water is no more neon than Natural's")
        XCTAssertLessThan(dw.z, 270)
    }

    func testNeutralRampStaysNeutralForEveryPreset() throws {
        // A grey ramp up to white through the whole chain, photo and video paths. A grey scene gets no
        // Tropical warmth, so every preset keeps it colourless.
        let grey = WaterAnalysis(redLoss: 0, cyanDominance: 0, exposure: 0.05, contrast: 0.6, saturation: 0,
                                 meanRed: 0.2, meanGreen: 0.2, meanBlue: 0.2, midLuminance: 0.2,
                                 waterRed: 0.1, waterGreen: 0.1, waterBlue: 0.1)
        let width = 64, height = 8
        let ramp = (0..<(width * height)).map { Float($0 % width) / Float(width - 1) }
        var rgba = [Float](); rgba.reserveCapacity(ramp.count * 4)
        for value in ramp { rgba += [value, value, value, 1] }
        let source = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                             size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
        let map = try NormalizedDepthMap(width: width, height: height, values: ramp)
        let depth = DepthEstimate(map: map, source: .monocular, statistics: .init(minimum: 0, maximum: 1, median: 0.5),
                                  confidence: 0.9, inferenceMilliseconds: nil)
        let plan = try WaterModelEstimator().estimate(image: source, depth: depth, legacy: grey, context: engine.context)
        for preset in [DivePreset.natural, .tropical, .deep] {
            XCTAssertEqual(ColorCorrection.make(analysis: grey, preset: preset).warmth, 0)
            let settings = FilterSettings(preset: preset, intensity: 0.8, analysis: grey)
            for p in [plan, try plan.sceneLevel()] {
                let out = try RestorationEngine().combined(source, plan: p, settings: settings, filter: engine)
                var pixels = [Float](repeating: 0, count: width * height * 4)
                engine.context.render(out, toBitmap: &pixels, rowBytes: width * 16, bounds: source.extent,
                                      format: .RGBAf, colorSpace: FilterEngine.workingSpace)
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    XCTAssertLessThan(ColorCorrection.lightnessChromaHue(SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])).y, 1, "\(preset)")
                }
            }
        }
    }

    func testTropicalWarmthOnGreyIsWarmAndBounded() {
        // In an underwater scene Tropical warms. On a grey surface the warmth alone (Tropical values
        // against the same values with warmth removed) must read warm, never cool, and stay a light tint.
        let analysis = PresetFixtures.scene(water: .init(0.02, 0.2, 0.6))
        let warm = ColorCorrection.make(analysis: analysis, preset: .tropical)
        XCTAssertEqual(warm.warmth, DivePreset.tropical.warmth)
        var plain = warm; plain.warmth = 0
        for level: Float in [0.05, 0.2, 0.5] {
            let grey = CIImage(color: CIColor(red: CGFloat(level), green: CGFloat(level), blue: CGFloat(level), colorSpace: FilterEngine.workingSpace)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let a = ColorCorrection.lab(pixel(engine.apply(grey, correction: warm, intensity: 0.8), x: 4, y: 4))
            let b = ColorCorrection.lab(pixel(engine.apply(grey, correction: plain, intensity: 0.8), x: 4, y: 4))
            XCTAssertGreaterThan(a.z, b.z, "warmth must add yellow")
            // Measured at 600 K and intensity 0.8: b* +1.8 to +4.6, a* -0.3 to -1.0 (yellow, not orange).
            XCTAssertLessThan(hypot(a.y - b.y, a.z - b.z), 5, "the warmth tint stays light")
            XCTAssertLessThan(abs(a.y - b.y), 1.5, "the warmth is yellow, not orange or magenta")
        }
    }
}

// Fixed analyses and plans for the Natural Dive pin. Shared by the pin generator and PresetTests.
enum PresetFixtures {
    static func scene(water: SIMD3<Float>, mid: Float = 0.12, contrast: Float = 0.2) -> WaterAnalysis {
        let mean = water + SIMD3(0.04, 0.02, 0)
        let surviving = (mean.y + mean.z) / 2
        return WaterAnalysis(redLoss: max(0, 1 - mean.x / surviving), cyanDominance: max(0, 1 - mean.x / surviving),
                             exposure: 0.02, contrast: contrast, saturation: 0.6, meanRed: mean.x, meanGreen: mean.y,
                             meanBlue: mean.z, midLuminance: mid, waterRed: water.x, waterGreen: water.y, waterBlue: water.z)
    }
    static var analyses: [(String, WaterAnalysis)] {
        var sand = scene(water: .init(0.01, 0.23, 0.65), mid: 0.2, contrast: 0.3)
        sand.neutralRed = 0.28; sand.neutralGreen = 0.59; sand.neutralBlue = 0.67; sand.neutralShare = 0.2; sand.highShare = 0.3
        var grey = WaterAnalysis(redLoss: 0, cyanDominance: 0, exposure: 0, contrast: 0.6, saturation: 0,
                                 meanRed: 0.2, meanGreen: 0.2, meanBlue: 0.2, midLuminance: 0.2,
                                 waterRed: 0.1, waterGreen: 0.1, waterBlue: 0.1)
        grey.neutralRed = 0.5; grey.neutralGreen = 0.5; grey.neutralBlue = 0.5; grey.neutralShare = 0.2; grey.highShare = 0.3
        return [("blue", scene(water: .init(0.02, 0.2, 0.6))),
                ("neon", scene(water: .init(0.01, 0.05, 0.7), mid: 0.05, contrast: 0.15)),
                ("teal", scene(water: .init(0.03, 0.4, 0.38), mid: 0.15)),
                ("bright", scene(water: .init(0.05, 0.35, 0.6), mid: 0.3, contrast: 0.4)),
                ("sand", sand), ("grey", grey)]
    }
    static func plan() throws -> RestorationPlan {
        let map = try NormalizedDepthMap(width: 2, height: 2, values: [0.3, 0.5, 0.6, 0.8])
        return RestorationPlan(depth: map, depthSource: .monocular,
            depthStatistics: .init(minimum: 0.3, maximum: 0.8, median: 0.55),
            backscatterInfinity: .init(0.08, 0.18, 0.32), betaDirect: .init(0.9, 0.45, 0.25),
            betaBackscatter: .init(0.55, 0.42, 0.31), confidence: 0.7, limits: .init(),
            transmissionFloorPixelPercentage: 0, maximumGainPixelPercentage: 0)
    }
    /// Every ColorCorrection field, as Swift prints it (a round-trip exact Float form).
    static func flat(_ c: ColorCorrection) -> String {
        Mirror(reflecting: c).children.map { "\($0.label ?? "?")=\($0.value)" }.joined(separator: ";")
    }
    static func naturalValues() throws -> [String] {
        let p = try plan(), u = try p.sceneLevel()
        return analyses.flatMap { name, a in
            [("source", nil), ("plan", p), ("uniform", u)].map { path, plan in
                "\(name)|\(path)|" + flat(ColorCorrection.make(analysis: a, preset: .natural, plan: plan as RestorationPlan?))
            }
        }
    }
}
