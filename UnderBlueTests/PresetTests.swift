import XCTest
import CoreImage
@testable import UnderBlue

/// Preset looks. Natural Dive is the automatic result and the base for user presets, so its values
/// are pinned. Tropical and Deep Dive are checked against Natural Dive on the same scene.
final class PresetTests: XCTestCase {
    let engine = FilterEngine()

    /// Natural Dive values from the rules after the AquaColorFix tuning of 28 Sep 2026 (subject light
    /// removal, azure water goal, trusted blue white reference, lower lifts, the fine detail layer, softer tones) and the
    /// bright-scene reference adaptation of 29 Sep 2026 (`edcc663`), on fixed analyses, without a
    /// plan, with a per-pixel plan and with its constant-depth (video) version. Any change to them is a
    /// product change. Regenerate them by printing PresetFixtures.naturalValues().
    static let pinnedNatural: [String] = [
        "blue|source|castGains=SIMD3<Float>(1.3184863, 0.9797542, 0.9797542);redRebuild=0.49650913;redGateLow=0.76625353;redGateHigh=1.1662536;subjectRed=0.63403565;waterTone=SIMD3<Float>(1.3072587, 1.00416, 0.77952147);waterRedness=0.03364329;waterSaturation=0.5829506;waterChroma=0.95514226;waterType=0.04583329;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.12999997;tonePivot=0.3814574;brightness=0.009;contrast=1.0649999;saturation=0.8960206;shadowLift=0.275;highlightAmount=0.82;clarity=0.09504;clarityRadius=0.013541667;definition=0.0864;definitionRadius=0.04;detail=1.17;detailFloor=0.0056000003;detailRadius=0.0025000002;warmth=0.0;vibrance=0.004613936;physicalWeight=0.0;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.026369726, 0.19595085, 0.58785254);lightGradient=0.0",
        "blue|plan|castGains=SIMD3<Float>(1.3184863, 0.9797542, 0.9797542);redRebuild=0.49650913;redGateLow=0.7676907;redGateHigh=1.1676908;subjectRed=0.49911928;waterTone=SIMD3<Float>(1.3374077, 0.99259526, 0.809692);waterRedness=0.03364329;waterSaturation=0.5143687;waterChroma=0.95514226;waterType=0.04583329;redCeiling=1.05;violetGuard=1.0;midLift=0.117236994;toneCurve=0.12999997;tonePivot=0.3814574;brightness=0.009;contrast=1.0649999;saturation=0.8960206;shadowLift=0.275;highlightAmount=0.82;clarity=0.09504;clarityRadius=0.013541667;definition=0.0864;definitionRadius=0.04;detail=1.17;detailFloor=0.0056000003;detailRadius=0.0025000002;warmth=0.0;vibrance=0.004613936;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.0, 0.20438756, 0.6181121);lightGradient=0.0",
        "blue|uniform|castGains=SIMD3<Float>(1.3184863, 0.9797542, 0.9797542);redRebuild=0.49650913;redGateLow=0.7683314;redGateHigh=1.1683314;subjectRed=0.49930206;waterTone=SIMD3<Float>(1.3369653, 0.9927537, 0.8090274);waterRedness=0.03364329;waterSaturation=0.5139139;waterChroma=0.95514226;waterType=0.04583329;redCeiling=1.05;violetGuard=1.0;midLift=0.114631936;toneCurve=0.12999997;tonePivot=0.3814574;brightness=0.009;contrast=1.0649999;saturation=0.8960206;shadowLift=0.275;highlightAmount=0.82;clarity=0.09504;clarityRadius=0.013541667;definition=0.0864;definitionRadius=0.04;detail=1.17;detailFloor=0.0056000003;detailRadius=0.0025000002;warmth=0.0;vibrance=0.004613936;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.0, 0.20522778, 0.6211627);lightGradient=0.0",
        "neon|source|castGains=SIMD3<Float>(1.3083414, 0.9674201, 0.9674201);redRebuild=0.51685715;redGateLow=0.4881422;redGateHigh=0.8881422;subjectRed=0.38600683;waterTone=SIMD3<Float>(0.9995321, 1.4768815, 0.4543716);waterRedness=0.018032033;waterSaturation=0.71873295;waterChroma=0.98068;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.14071424;tonePivot=0.3;brightness=0.009;contrast=1.0739285;saturation=0.88;shadowLift=0.3017857;highlightAmount=0.7842857;clarity=0.10224;clarityRadius=0.014657738;definition=0.100114286;definitionRadius=0.04;detail=0.7602678;detailFloor=0.008;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0;physicalWeight=0.0;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.013083413, 0.048371006, 0.67719406);lightGradient=0.0",
        "neon|plan|castGains=SIMD3<Float>(1.3083414, 0.9674201, 0.9674201);redRebuild=0.51685715;redGateLow=0.44247133;redGateHigh=0.84247136;subjectRed=0.6490668;waterTone=SIMD3<Float>(0.9993452, 2.0009587, 0.37176314);waterRedness=0.018032033;waterSaturation=0.6672121;waterChroma=0.98068;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.44776073;toneCurve=0.14071424;tonePivot=0.3;brightness=0.009;contrast=1.0739285;saturation=0.88;shadowLift=0.3017857;highlightAmount=0.7842857;clarity=0.10224;clarityRadius=0.014657738;definition=0.100114286;definitionRadius=0.04;detail=0.7602678;detailFloor=0.008;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.0, 0.01595095, 0.72133255);lightGradient=0.0",
        "neon|uniform|castGains=SIMD3<Float>(1.3083414, 0.9674201, 0.9674201);redRebuild=0.51685715;redGateLow=0.42783007;redGateHigh=0.8278301;subjectRed=0.6591269;waterTone=SIMD3<Float>(0.995732, 2.049054, 0.3743284);waterRedness=0.018032033;waterSaturation=0.6498546;waterChroma=0.98068;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.4658031;toneCurve=0.14071424;tonePivot=0.3;brightness=0.009;contrast=1.0739285;saturation=0.88;shadowLift=0.3017857;highlightAmount=0.7842857;clarity=0.10224;clarityRadius=0.014657738;definition=0.100114286;definitionRadius=0.04;detail=0.7602678;detailFloor=0.008;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.0, 0.012551267, 0.725741);lightGradient=0.0",
        "teal|source|castGains=SIMD3<Float>(1.4154601, 0.9641136, 1.1675459);redRebuild=0.46074075;redGateLow=0.55;redGateHigh=0.95000005;subjectRed=0.68544066;waterTone=SIMD3<Float>(1.5361629, 0.904038, 1.2849795);waterRedness=0.051203594;waterSaturation=0.62568593;waterChroma=0.9042891;waterType=1.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.12999997;tonePivot=0.42217845;brightness=0.009;contrast=1.0649999;saturation=0.8998426;shadowLift=0.275;highlightAmount=0.82;clarity=0.09504;clarityRadius=0.013541667;definition=0.0864;definitionRadius=0.04;detail=1.3893751;detailFloor=0.0044;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0057146586;physicalWeight=0.0;subjectTone=SIMD3<Float>(1.0, 0.6, 0.3911871);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.0424638, 0.38564545, 0.44366744);lightGradient=0.0",
        "teal|plan|castGains=SIMD3<Float>(1.4154601, 0.9641136, 1.1675459);redRebuild=0.46074075;redGateLow=0.55;redGateHigh=0.95000005;subjectRed=0.47030792;waterTone=SIMD3<Float>(1.616126, 0.89123243, 1.3846269);waterRedness=0.051203594;waterSaturation=0.59322745;waterChroma=0.9042891;waterType=1.0;redCeiling=1.05;violetGuard=1.0;midLift=0.034824207;toneCurve=0.12999997;tonePivot=0.42217845;brightness=0.009;contrast=1.0649999;saturation=0.8998426;shadowLift=0.275;highlightAmount=0.82;clarity=0.09504;clarityRadius=0.013541667;definition=0.0864;definitionRadius=0.04;detail=1.3893751;detailFloor=0.0044;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0057146586;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.02117133, 0.4480958, 0.44186524);lightGradient=0.0",
        "teal|uniform|castGains=SIMD3<Float>(1.4154601, 0.9641136, 1.1675459);redRebuild=0.46074075;redGateLow=0.55;redGateHigh=0.95000005;subjectRed=0.47076958;waterTone=SIMD3<Float>(1.6248958, 0.8900779, 1.3935846);waterRedness=0.051203594;waterSaturation=0.5884843;waterChroma=0.9042891;waterType=1.0;redCeiling=1.05;violetGuard=1.0;midLift=0.024930133;toneCurve=0.12999997;tonePivot=0.42217845;brightness=0.009;contrast=1.0649999;saturation=0.8998426;shadowLift=0.275;highlightAmount=0.82;clarity=0.09504;clarityRadius=0.013541667;definition=0.0864;definitionRadius=0.04;detail=1.3893751;detailFloor=0.0044;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0057146586;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.01754878, 0.45454246, 0.44179344);lightGradient=0.0",
        "bright|source|castGains=SIMD3<Float>(1.3046706, 0.9810694, 0.9810694);redRebuild=0.4022763;redGateLow=0.6426536;redGateHigh=1.0426536;subjectRed=0.69053286;waterTone=SIMD3<Float>(1.4107218, 0.94433767, 0.9948032);waterRedness=0.069991864;waterSaturation=0.6346159;waterChroma=0.8891795;waterType=0.6293858;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.0833333;tonePivot=0.57853264;brightness=-0.020649133;contrast=1.04;saturation=0.93256825;shadowLift=0.23333335;highlightAmount=0.92;clarity=0.074880004;clarityRadius=0.010416667;definition=0.048;definitionRadius=0.04;detail=1.3;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.018924559;physicalWeight=0.0;subjectTone=SIMD3<Float>(1.0, 0.6, 0.41480878);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.06523353, 0.34337428, 0.58864164);lightGradient=0.0",
        "bright|plan|castGains=SIMD3<Float>(1.3046706, 0.9810694, 0.9810694);redRebuild=0.4022763;redGateLow=0.6426536;redGateHigh=1.0426536;subjectRed=0.5120647;waterTone=SIMD3<Float>(1.4554317, 0.9338635, 1.0379728);waterRedness=0.069991864;waterSaturation=0.6199565;waterChroma=0.8891795;waterType=0.6293858;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.0833333;tonePivot=0.57853264;brightness=-0.020649133;contrast=1.04;saturation=0.93256825;shadowLift=0.23333335;highlightAmount=0.92;clarity=0.074880004;clarityRadius=0.010416667;definition=0.048;definitionRadius=0.04;detail=1.3;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.018924559;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.39920157);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.062320426, 0.3931478, 0.6189418);lightGradient=0.0",
        "bright|uniform|castGains=SIMD3<Float>(1.3046706, 0.9810694, 0.9810694);redRebuild=0.4022763;redGateLow=0.6426536;redGateHigh=1.0426536;subjectRed=0.5124664;waterTone=SIMD3<Float>(1.4641386, 0.9324241, 1.0431228);waterRedness=0.069991864;waterSaturation=0.61477894;waterChroma=0.8891795;waterType=0.6293858;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.0833333;tonePivot=0.57853264;brightness=-0.020649133;contrast=1.04;saturation=0.93256825;shadowLift=0.23333335;highlightAmount=0.92;clarity=0.074880004;clarityRadius=0.010416667;definition=0.048;definitionRadius=0.04;detail=1.3;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.018924559;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.3903908);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.05922935, 0.39827815, 0.6219965);lightGradient=0.0",
        "sand|source|castGains=SIMD3<Float>(1.3383317, 0.98406744, 0.98406744);redRebuild=0.49978325;redGateLow=0.77060753;redGateHigh=1.1706076;subjectRed=0.63993824;waterTone=SIMD3<Float>(1.3412472, 0.98883593, 0.82051456);waterRedness=0.015454546;waterSaturation=0.54394317;waterChroma=0.9790769;waterType=0.117569864;redCeiling=1.05;violetGuard=1.0;midLift=-0.12;toneCurve=0.108571395;tonePivot=0.48115653;brightness=0.0045;contrast=1.0471429;saturation=0.88;shadowLift=0.20857143;highlightAmount=0.8914286;clarity=0.08064;clarityRadius=0.011309523;definition=0.05897143;definitionRadius=0.04;detail=1.3464285;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0;physicalWeight=0.0;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(4.469317, 0.49408793, 0.45285022);referenceStrength=0.09177271;waterLit=SIMD3<Float>(0.013383317, 0.22633551, 0.6396438);lightGradient=0.0",
        "sand|plan|castGains=SIMD3<Float>(1.3383317, 0.98406744, 0.98406744);redRebuild=0.49978325;redGateLow=0.77060753;redGateHigh=1.1706076;subjectRed=0.45692626;waterTone=SIMD3<Float>(1.353804, 0.98268574, 0.83803326);waterRedness=0.015454546;waterSaturation=0.5123106;waterChroma=0.9790769;waterType=0.117569864;redCeiling=1.05;violetGuard=1.0;midLift=-0.12;toneCurve=0.108571395;tonePivot=0.48115653;brightness=0.0045;contrast=1.0471429;saturation=0.88;shadowLift=0.20857143;highlightAmount=0.8914286;clarity=0.08064;clarityRadius=0.011309523;definition=0.05897143;definitionRadius=0.04;detail=1.3464285;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(2.2201736, 0.66273534, 0.6796306);referenceStrength=0.09177271;waterLit=SIMD3<Float>(0.0, 0.24309973, 0.67728925);lightGradient=0.0",
        "sand|uniform|castGains=SIMD3<Float>(1.3383317, 0.98406744, 0.98406744);redRebuild=0.49978325;redGateLow=0.77060753;redGateHigh=1.1706076;subjectRed=0.4572982;waterTone=SIMD3<Float>(1.3539157, 0.982526, 0.8383079);waterRedness=0.015454546;waterSaturation=0.51180494;waterChroma=0.9790769;waterType=0.117569864;redCeiling=1.05;violetGuard=1.0;midLift=-0.12;toneCurve=0.108571395;tonePivot=0.48115653;brightness=0.0045;contrast=1.0471429;saturation=0.88;shadowLift=0.20857143;highlightAmount=0.8914286;clarity=0.08064;clarityRadius=0.011309523;definition=0.05897143;definitionRadius=0.04;detail=1.3464285;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.0;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 0.6, 0.35);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(2.1755333, 0.66116077, 0.695228);referenceStrength=0.09177271;waterLit=SIMD3<Float>(0.0, 0.24480407, 0.6810634);lightGradient=0.0",
        "grey|source|castGains=SIMD3<Float>(1.0, 1.0, 1.0);redRebuild=0.0;redGateLow=0.8;redGateHigh=1.2;subjectRed=1.0;waterTone=SIMD3<Float>(1.0, 1.0, 1.0);waterRedness=0.5;waterSaturation=1.0;waterChroma=0.0;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.0;toneCurve=0.099999964;tonePivot=0.48115653;brightness=0.0;contrast=1.04;saturation=1.08;shadowLift=0.2;highlightAmount=0.92;clarity=0.074880004;clarityRadius=0.010416667;definition=0.048;definitionRadius=0.04;detail=1.3;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.18;physicalWeight=0.0;subjectTone=SIMD3<Float>(1.0, 1.0, 1.0);neutralGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.1, 0.1, 0.1);lightGradient=0.0",
        "grey|plan|castGains=SIMD3<Float>(1.0, 1.0, 1.0);redRebuild=0.0;redGateLow=0.8;redGateHigh=1.2;subjectRed=1.0;waterTone=SIMD3<Float>(1.0, 1.0, 1.0);waterRedness=0.5847601;waterSaturation=1.0;waterChroma=0.0;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.05937817;toneCurve=0.099999964;tonePivot=0.48115653;brightness=0.0;contrast=1.04;saturation=1.08;shadowLift=0.2;highlightAmount=0.92;clarity=0.074880004;clarityRadius=0.010416667;definition=0.048;definitionRadius=0.04;detail=1.3;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.18;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 1.0, 1.0);neutralGains=SIMD3<Float>(1.0001144, 0.9999655, 1.0000072);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.08052911, 0.0805291, 0.057183955);lightGradient=0.0",
        "grey|uniform|castGains=SIMD3<Float>(1.0, 1.0, 1.0);redRebuild=0.0;redGateLow=0.8;redGateHigh=1.2;subjectRed=1.0;waterTone=SIMD3<Float>(1.0, 1.0, 1.0);waterRedness=0.59650385;waterSaturation=1.0;waterChroma=0.0;waterType=0.0;redCeiling=1.05;violetGuard=1.0;midLift=0.056776643;toneCurve=0.099999964;tonePivot=0.48115653;brightness=0.0;contrast=1.04;saturation=1.08;shadowLift=0.2;highlightAmount=0.92;clarity=0.074880004;clarityRadius=0.010416667;definition=0.048;definitionRadius=0.04;detail=1.3;detailFloor=0.004;detailRadius=0.0025000002;warmth=0.0;vibrance=0.18;physicalWeight=0.7;subjectTone=SIMD3<Float>(1.0, 1.0, 1.0);neutralGains=SIMD3<Float>(1.0004988, 0.9998492, 1.0000303);referenceGains=SIMD3<Float>(1.0, 1.0, 1.0);referenceStrength=0.0;waterLit=SIMD3<Float>(0.07847219, 0.07847218, 0.053081356);lightGradient=0.0"
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

    func testPresetWaterHueGoalIsUsed() {
        // The clear-water target moves to the goal it is given; the default stays azure.
        let water = SIMD3<Float>(0.45, 0.15, 258)
        XCTAssertEqual(ColorCorrection.waterTarget(water, waterType: 0, murky: 0, goal: DivePreset.tropical.waterHue).z,
                       DivePreset.tropical.waterHue, accuracy: 1e-3)
        XCTAssertEqual(ColorCorrection.waterTarget(water, waterType: 0, murky: 0).z, ColorCorrection.waterHueGoal, accuracy: 1e-3)
        XCTAssertEqual(DivePreset.natural.waterHue, ColorCorrection.waterHueGoal)
        XCTAssertEqual(DivePreset.custom.waterHue, ColorCorrection.waterHueGoal)
        XCTAssertEqual(DivePreset.deep.waterHue, ColorCorrection.waterHueGoal)
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
