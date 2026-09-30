import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd
import ImageIO
import UniformTypeIdentifiers

// Usage: eval <rawDir> <refDir|-> <outCSV> [all|dev|holdout|N] [sheetDir] [sheetNamesFile]
let args = CommandLine.arguments
let rawDir = URL(fileURLWithPath: args[1])
let refDir: URL? = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
let outCSV = args[3]
let split = args.count > 4 ? args[4] : "all"
let sheetDir: URL? = args.count > 5 ? URL(fileURLWithPath: args[5]) : nil
let sheetNames: Set<String>? = args.count > 6 ? Set(try String(contentsOfFile: args[6], encoding: .utf8).split(separator: "\n").map(String.init)) : nil
// HT_EVAL_MAXDIM overrides the render size (the AquaColorFix benchmark measures at 960).
let maxDim: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["HT_EVAL_MAXDIM"] ?? "") ?? 640)

let engine = FilterEngine()
let depthEstimator = DepthEstimator()
let waterEstimator = WaterModelEstimator()
let restoration = RestorationEngine()
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ url: URL) -> CIImage? { CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) }
func fit(_ image: CIImage, width: Int, height: Int) -> CIImage {
    let t = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    return t.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / t.extent.width, y: CGFloat(height) / t.extent.height))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}
func render(_ image: CIImage, _ w: Int, _ h: Int) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    engine.context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                          format: .RGBA8, colorSpace: sRGB)
    return px
}
func save(_ image: CIImage, _ url: URL) {
    guard let cg = engine.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB),
          let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(d)
    // Lossless companion for patch colour and noise measurements. Keep JPEG sheets compatible.
    if ProcessInfo.processInfo.environment["HT_EVAL_PNG"] == "1",
       let png = CGImageDestinationCreateWithURL(url.deletingPathExtension().appendingPathExtension("png") as CFURL,
                                                UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(png, cg, nil)
        CGImageDestinationFinalize(png)
    }
}
func grayWorld(_ image: CIImage) -> CIImage {
    let avg = CIFilter.areaAverage(); avg.inputImage = image; avg.extent = image.extent
    var m = [Float](repeating: 0, count: 4)
    engine.context.render(avg.outputImage!, toBitmap: &m, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                          format: .RGBAf, colorSpace: FilterEngine.workingSpace)
    let mean = (m[0] + m[1] + m[2]) / 3
    let g = (0..<3).map { CGFloat(min(4, mean / max(0.002, m[$0]))) }
    let f = CIFilter.colorMatrix(); f.inputImage = image
    f.rVector = CIVector(x: g[0], y: 0, z: 0, w: 0); f.gVector = CIVector(x: 0, y: g[1], z: 0, w: 0)
    f.bVector = CIVector(x: 0, y: 0, z: g[2], w: 0)
    return f.outputImage!.cropped(to: image.extent)
}

// sRGB8 -> Lab (D65)
func lab(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> SIMD3<Float> {
    func lin(_ v: UInt8) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let r = lin(r8), g = lin(g8), b = lin(b8)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
    return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
}
struct Metrics { var psnr = Float.nan, ssim = Float.nan, deltaE = Float.nan
    var farHue: Float = 0, farChroma: Float = 0, nearA: Float = 0, nearRG: Float = 0, contrastL: Float = 0
    var meanL: Float = 0, localContrast: Float = 0, farLocalContrast: Float = 0
    var farHueOK: Float = 0, farChromaOK: Float = 0 }

// OKLab (a, b) of an sRGB8 pixel. OKLab hue separates azure, blue, indigo and violet, where CIELAB hue does not.
func okab(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> SIMD2<Float> {
    func lin(_ v: UInt8) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    let r = lin(r8), g = lin(g8), b = lin(b8)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return SIMD2(1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}
func toneMetrics(_ px: [UInt8], _ w: Int, _ h: Int, depth: NormalizedDepthMap) -> Metrics {
    var m = Metrics()
    var farOK = SIMD2<Float>(0, 0)
    var far = SIMD2<Float>(0, 0), farN: Float = 0, nearA: Float = 0, nearR: Float = 0, nearG: Float = 0, nearN: Float = 0
    var Ls: [Float] = []; Ls.reserveCapacity(w * h)
    let sorted = depth.values.sorted()
    let farCut = sorted[sorted.count * 7 / 10], nearCut = sorted[sorted.count * 3 / 10]
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let l = lab(px[i], px[i+1], px[i+2]); Ls.append(l.x)
        let d = depth.values[(y * depth.height / h) * depth.width + (x * depth.width / w)]
        if d >= farCut { far += SIMD2(l.y, l.z); farOK += okab(px[i], px[i+1], px[i+2]); farN += 1 }
        if d <= nearCut { nearA += l.y; nearR += Float(px[i]); nearG += Float(px[i+1]); nearN += 1 }
    } }
    far /= max(1, farN)
    var hue = atan2(far.y, far.x) * 180 / .pi; if hue < 0 { hue += 360 }
    m.farHue = hue; m.farChroma = sqrt(far.x * far.x + far.y * far.y)
    farOK /= max(1, farN)
    var hueOK = atan2(farOK.y, farOK.x) * 180 / .pi; if hueOK < 0 { hueOK += 360 }
    m.farHueOK = hueOK; m.farChromaOK = sqrt(farOK.x * farOK.x + farOK.y * farOK.y)
    m.nearA = nearA / max(1, nearN); m.nearRG = nearR / max(1, nearG)
    let mean = Ls.reduce(0, +) / Float(Ls.count)
    m.contrastL = sqrt(Ls.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(Ls.count))
    m.meanL = mean
    // Haze proxy independent of hue: a veil lowers local L* contrast. 16x16 non-overlapping windows.
    var local: Float = 0, localN: Float = 0, farLocal: Float = 0, farLocalN: Float = 0
    for y0 in stride(from: 0, through: h - 16, by: 16) { for x0 in stride(from: 0, through: w - 16, by: 16) {
        var s: Float = 0, s2: Float = 0
        for y in y0..<(y0 + 16) { for x in x0..<(x0 + 16) { let v = Ls[y * w + x]; s += v; s2 += v * v } }
        let sd = sqrt(max(0, s2 / 256 - (s / 256) * (s / 256)))
        local += sd; localN += 1
        let d = depth.values[((y0 + 8) * depth.height / h) * depth.width + ((x0 + 8) * depth.width / w)]
        if d >= farCut { farLocal += sd; farLocalN += 1 }
    } }
    m.localContrast = local / max(1, localN); m.farLocalContrast = farLocal / max(1, farLocalN)
    return m
}
func fullReference(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int, into m: inout Metrics) {
    var se: Double = 0, de: Double = 0
    var la = [Float](repeating: 0, count: w * h), lb = la
    for p in 0..<(w * h) {
        let i = p * 4
        for c in 0..<3 { let d = Double(a[i+c]) - Double(b[i+c]); se += d * d }
        let x = lab(a[i], a[i+1], a[i+2]), y = lab(b[i], b[i+1], b[i+2])
        de += Double(simd_length(x - y)); la[p] = x.x; lb[p] = y.x
    }
    let mse = se / Double(w * h * 3)
    m.psnr = Float(10 * log10(255 * 255 / max(mse, 1e-10))); m.deltaE = Float(de / Double(w * h))
    // SSIM on L*, 8x8 box windows, stride 4.
    let c1: Float = pow(0.01 * 100, 2), c2: Float = pow(0.03 * 100, 2)
    var total: Float = 0, n: Float = 0
    for y in stride(from: 0, through: h - 8, by: 4) { for x in stride(from: 0, through: w - 8, by: 4) {
        var ma: Float = 0, mb: Float = 0
        for j in 0..<8 { for k in 0..<8 { ma += la[(y+j)*w+x+k]; mb += lb[(y+j)*w+x+k] } }
        ma /= 64; mb /= 64
        var va: Float = 0, vb: Float = 0, cv: Float = 0
        for j in 0..<8 { for k in 0..<8 { let p = la[(y+j)*w+x+k] - ma, q = lb[(y+j)*w+x+k] - mb; va += p*p; vb += q*q; cv += p*q } }
        va /= 63; vb /= 63; cv /= 63
        total += ((2*ma*mb + c1) * (2*cv + c2)) / ((ma*ma + mb*mb + c1) * (va + vb + c2)); n += 1
    } }
    m.ssim = total / max(1, n)
}

let variants = ["original", "grayworld", "current", "restoration", "combined", "uniform", "reference"]
var csv = "image,variant,psnr,ssim,deltaE,farHue,farChroma,nearA,nearRG,contrastL,meanL,localContrast,farLocalContrast,farHueOK,farChromaOK,fallback,confidence,depthConf,waterConf,betaDR,betaDG,betaDB,binfR,binfG,binfB,floorPct,gainPct,recR\n"
let files = try FileManager.default.contentsOfDirectory(atPath: rawDir.path).filter { [".png", ".jpg", ".jpeg"].contains(where: $0.lowercased().hasSuffix) }.sorted()
let started = Date()
var done = 0
// "dev:N" = visual-set names + first N dev images; "holdout:N" = first N holdout images.
let parts = split.split(separator: ":").map(String.init)
let cap = parts.count > 1 ? Int(parts[1]) ?? .max : .max
var taken = 0
let selected: [String] = files.enumerated().compactMap { i, f in
    switch parts[0] {
    case "dev", "holdout":
        guard (i % 2 == 1) == (parts[0] == "dev") else { return nil }
        if parts[0] == "dev", sheetNames?.contains(f) ?? false { return f }
        guard taken < cap else { return nil }
        taken += 1; return f
    case "all": return f
    default: return i < (Int(split) ?? .max) ? f : nil }
}
for name in selected {
    guard let rawFull = load(rawDir.appendingPathComponent(name)) else { continue }
    let scale = min(1, maxDim / max(rawFull.extent.width, rawFull.extent.height))
    let w = Int(rawFull.extent.width * scale), h = Int(rawFull.extent.height * scale)
    let source = fit(engine.sdr(rawFull), width: w, height: h)
    let analysis = engine.analyze(source)
    var settings = FilterSettings(); settings.analysis = analysis
    var plan: RestorationPlan?
    var depthMap: NormalizedDepthMap?
    do {
        let depth = try await depthEstimator.monocularDepth(for: source)
        depthMap = depth.map
        plan = try waterEstimator.estimate(image: source, depth: depth, legacy: analysis, context: engine.context)
    } catch { }
    guard let depthMap else { print("depth failed \(name)"); continue }
    let current = engine.apply(source, settings: settings)
    if ProcessInfo.processInfo.environment["HT_EVAL_LOG"] != nil {
        let a = analysis
        print("\(name) analysis: redLoss=\(a.redLoss) contrast=\(a.contrast) sat=\(a.saturation) mean=(\(a.meanRed),\(a.meanGreen),\(a.meanBlue)) mid=\(a.midLuminance) water=(\(a.waterRed),\(a.waterGreen),\(a.waterBlue)) neutral=(\(a.neutralRed),\(a.neutralGreen),\(a.neutralBlue)) share=\(a.neutralShare) high=\(a.highShare)")
        for (label, c) in [("current", ColorCorrection.make(analysis: analysis, preset: settings.preset)),
                           ("restored", plan.map { ColorCorrection.make(analysis: analysis, preset: settings.preset, plan: $0) })] {
            guard let c else { continue }
            // Reflection keeps this harness usable against older source snapshots without these fields.
            let referenceValues = Mirror(reflecting: c).children.filter { $0.label?.hasPrefix("reference") == true }
            if !referenceValues.isEmpty {
                print("\(name) \(label) adaptation: " + referenceValues.map { "\($0.label!)=\($0.value)" }.joined(separator: " "))
            }
            print("\(name) \(label): gains=(\(c.castGains.x),\(c.castGains.y),\(c.castGains.z)) water=(\(c.waterTone.x),\(c.waterTone.y),\(c.waterTone.z))x\(c.waterSaturation) redness=\(c.waterRedness) chroma=\(c.waterChroma) type=\(c.waterType) guard=\(c.violetGuard) gate=\(c.redGateLow) rebuild=\(c.redRebuild) subjectRed=\(c.subjectRed) midLift=\(c.midLift) curve=\(c.toneCurve)@\(c.tonePivot) bright=\(c.brightness) contrast=\(c.contrast) sat=\(c.saturation) shadows=\(c.shadowLift) clarity=\(c.clarity) def=\(c.definition) vib=\(c.vibrance) weight=\(c.physicalWeight) neutral=(\(c.neutralGains.x),\(c.neutralGains.y),\(c.neutralGains.z)) subject=(\(c.subjectTone.x),\(c.subjectTone.y),\(c.subjectTone.z)) waterLit=(\(c.waterLit.x),\(c.waterLit.y),\(c.waterLit.z))")
        }
        // Probe: one colour (working space, linear) through the colour kernel alone and through the whole
        // finishing chain, so a tuning run can see what each stage does to the water, the neutral surface and the subject.
        func probe(_ c: SIMD3<Float>, _ v: ColorCorrection) -> String {
            let kernel = FinishingMath.color(c, correction: v)
            let color = CIImage(color: CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), colorSpace: FilterEngine.workingSpace)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            var px = [Float](repeating: 0, count: 4)
            engine.context.render(engine.finishing(color, correction: v), toBitmap: &px, rowBytes: 16,
                                  bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBAf, colorSpace: FilterEngine.workingSpace)
            func f(_ x: SIMD3<Float>) -> String { let l = ColorCorrection.oklch(x); return "(\(String(format: "%.3f,%.3f,%.3f", x.x, x.y, x.z))) h\(Int(l.z)) C\(String(format: "%.3f", l.y))" }
            return "in \(f(c)) -> kernel \(f(kernel)) waterLike \(String(format: "%.2f", FinishingMath.waterLike(c * v.castGains, correction: v))) neutralW \(String(format: "%.2f", FinishingMath.neutralWeight(c * v.castGains, correction: v))) -> chain \(f(SIMD3(px[0], px[1], px[2])))"
        }
        let currentValues = ColorCorrection.make(analysis: analysis, preset: settings.preset)
        for (label, c) in [("water", a.waterColor), ("neutral", a.neutralColor), ("mean", a.meanColor)] where c.max() > 0 {
            print("\(name) probe current \(label): \(probe(c, currentValues))")
            if let plan {
                let v = ColorCorrection.make(analysis: analysis, preset: settings.preset, plan: plan)
                let sorted = plan.depth.values.sorted()
                let restored = ColorCorrection.restoredMean(c, plan: plan, depth: label == "neutral" ? sorted[sorted.count * 35 / 100] : nil)
                print("\(name) probe restored \(label): \(probe(restored, v))")
            }
        }
        if let p = plan { print("\(name) plan: conf=\(p.confidence) depthConf=\(p.depthConfidence) fit=\(p.waterFitConfidence) binf=\(p.backscatterInfinity) betaD=\(p.betaDirect) betaB=\(p.betaBackscatter) rec=\(p.channelRecoverability) medianDepth=\(p.depth.median)") }
    }
    var outputs: [String: CIImage] = ["original": source, "grayworld": grayWorld(source), "current": current]
    if let plan, let raw = try? restoration.restore(source, plan: plan) {
        outputs["restoration"] = engine.blend(source, raw, amount: plan.confidence)
        outputs["combined"] = (try? restoration.combined(source, plan: plan, settings: settings, filter: engine)) ?? current
        if let uniform = try? plan.withUniformDepth() {
            // The video entry point (correction values passed in), as video frames are rendered.
            outputs["uniform"] = (try? restoration.combined(source, plan: uniform, values: restoration.corrections(settings: settings, plan: uniform),
                                                            settings: settings, filter: engine)) ?? current
        }
    } else {
        outputs["restoration"] = source; outputs["combined"] = current; outputs["uniform"] = current
    }
    var refPx: [UInt8]?
    if let refDir, let ref = load(refDir.appendingPathComponent(name)) {
        outputs["reference"] = fit(ref, width: w, height: h); refPx = render(outputs["reference"]!, w, h)
    }
    for v in variants {
        guard let img = outputs[v] else { continue }
        let px = v == "reference" ? refPx! : render(img, w, h)
        var m = toneMetrics(px, w, h, depth: depthMap)
        if let refPx, v != "reference" { fullReference(px, refPx, w, h, into: &m) }
        let p = plan
        let fields: [String] = [name, v, "\(m.psnr)", "\(m.ssim)", "\(m.deltaE)", "\(m.farHue)", "\(m.farChroma)", "\(m.nearA)",
            "\(m.nearRG)", "\(m.contrastL)", "\(m.meanL)", "\(m.localContrast)", "\(m.farLocalContrast)", "\(m.farHueOK)", "\(m.farChromaOK)", p == nil ? "1" : "0", "\(p?.confidence ?? 0)", "\(p?.depthConfidence ?? 0)",
            "\(p?.waterFitConfidence ?? 0)", "\(p?.betaDirect.x ?? 0)", "\(p?.betaDirect.y ?? 0)", "\(p?.betaDirect.z ?? 0)",
            "\(p?.backscatterInfinity.x ?? 0)", "\(p?.backscatterInfinity.y ?? 0)", "\(p?.backscatterInfinity.z ?? 0)",
            "\(p?.transmissionFloorPixelPercentage ?? 0)", "\(p?.maximumGainPixelPercentage ?? 0)", "\(p?.channelRecoverability.x ?? 0)"]
        csv += fields.joined(separator: ",") + "\n"
        if let sheetDir, sheetNames?.contains(name) ?? true { save(img, sheetDir.appendingPathComponent("\(name.split(separator: ".")[0])__\(v).jpg")) }
    }
    done += 1
    if done % 50 == 0 { print("\(done) images, \(Int(Date().timeIntervalSince(started)))s"); try csv.write(toFile: outCSV, atomically: true, encoding: .utf8) }
}
try csv.write(toFile: outCSV, atomically: true, encoding: .utf8)
print("done \(done) images in \(Int(Date().timeIntervalSince(started)))s")
