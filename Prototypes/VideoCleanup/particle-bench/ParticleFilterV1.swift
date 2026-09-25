import CoreImage
import CoreMedia
import CoreVideo

/// Removes marine snow from video: small bright specks that drift through the water.
///
/// A pixel is changed only when every test passes:
/// 1. Small, bright and isolated: its blurred luma is brighter than every point on a ring of `ringRadius` px
///    around it, by more than `floor` and more than `spreadGain` times the ring's own spread. Its contrast
///    over the ring mean must stay below `maxContrast`. Anything wider than the ring, any line or edge that crosses it, any spot in busy texture
///    and any very bright highlight fails this test.
/// 2. Drifting: camera motion is removed (global shift, then per 64 px block). A neighbour frame is usable
///    only when two rings around the spot (`contextRadius` and twice that) look the same there. A spot on a moving fish
///    or on badly aligned coral makes every neighbour unusable, so it is kept.
///    The spot is drifting when a usable neighbour has no peak of `matchRatio` of its strength (and at
///    least half its threshold) within 1 px. Slow specks that stay within 1 px are kept.
/// 3. Background fill: pixels within 4 px of a drifting spot take the mean of the unmarked ring pixels
///    around them (`fillRadius`). This also lifts the dark sharpening halo that cameras leave around specks.
///
/// Streaming use, same shape as `TemporalDenoiser`: `push` each frame in presentation order,
/// use every frame it returns, then call `finish` once. It holds 1 previous and 2 next frames,
/// so output lags input by 2 frames. Frame count, order and times never change.
/// Not thread-safe: one instance per export, called from one task.
final class ParticleFilterV1 {
    struct Frame {
        let image: CIImage
        let time: CMTime
    }

    /// Luma values are the square root of linear luma, 0...1. 1/219 is about one 8-bit video code.
    struct Settings: Sendable {
        var ringRadius: Float = 5
        var fillRadius: Float = 7
        var contextRadius: Float = 6
        var floor: Float = 4 / 219
        var spreadGain: Float = 2
        /// Spots brighter than this are never touched: in ambient light they are fish highlights, coral tips
        /// or bubbles, not marine snow. Strobe-lit backscatter above it is left alone too.
        var maxContrast: Float = 30 / 219
        var matchRatio: Float = 0.08
        /// A neighbour is usable when its mean ring difference is below this share of the spot's contrast
        /// plus half of `floor`. Texture does not widen it, so badly aligned coral is not usable.
        var contextTolerance: Float = 0.03
    }

    /// Camera motion between two frames from 1/4-scale luma: content at p in `a` sits at p + shift in `b`,
    /// in full-resolution pixels, y down. Coarse search on 1/8 scale (±80 px), then ±2 px refine and a
    /// parabola fit on 1/4 scale.
    struct MotionProbe: Sendable {
        let w: Int, h: Int
        let fine: [Float]
        let coarse: [Float]

        init(quarter: [Float], width: Int, height: Int) {
            w = width; h = height; fine = quarter
            let cw = width / 2, ch = height / 2
            var c = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw {
                let i = 2 * y * width + 2 * x
                c[y * cw + x] = (quarter[i] + quarter[i + 1] + quarter[i + width] + quarter[i + width + 1]) / 4
            }}
            coarse = c
        }

        func shift(to b: MotionProbe) -> SIMD2<Float> {
            let cw = w / 2, ch = h / 2
            var best = (Float.greatestFiniteMagnitude, 0, 0)
            for dy in -10...10 { for dx in -10...10 {
                let s = Self.sad(coarse, b.coarse, cw, ch, dx, dy, margin: 12)
                if s < best.0 { best = (s, dx, dy) }
            }}
            var cost = [[Float]](repeating: [Float](repeating: 0, count: 5), count: 5)
            var fineBest = (Float.greatestFiniteMagnitude, 0, 0)
            for j in 0..<5 { for i in 0..<5 {
                let dx = 2 * best.1 + i - 2, dy = 2 * best.2 + j - 2
                cost[j][i] = Self.sad(fine, b.fine, w, h, dx, dy, margin: 24)
                if cost[j][i] < fineBest.0 { fineBest = (cost[j][i], i, j) }
            }}
            func vertex(_ l: Float, _ m: Float, _ r: Float) -> Float {
                let d = l - 2 * m + r
                return d > 0 ? max(-0.5, min(0.5, (l - r) / (2 * d))) : 0
            }
            let (i, j) = (fineBest.1, fineBest.2)
            let sx = (i > 0 && i < 4) ? vertex(cost[j][i - 1], cost[j][i], cost[j][i + 1]) : 0
            let sy = (j > 0 && j < 4) ? vertex(cost[j - 1][i], cost[j][i], cost[j + 1][i]) : 0
            return SIMD2(Float(2 * best.1 + i - 2) + sx, Float(2 * best.2 + j - 2) + sy) * 4
        }

        /// Local motion per 64 px block. Search ±5 px on the 1/8-scale probe (±40 px) around `global`,
        /// then ±1 px and a parabola fit on the 1/4-scale probe. A block keeps `global` unless its best match
        /// is clearly better (flat water has no signal). A 3x3 median then removes single-block outliers.
        func field(to b: MotionProbe, global: SIMD2<Float>) -> MotionField {
            let gw = w / 16, gh = h / 16, cw = w / 2, ch = h / 2
            let g8 = global / 8, gx = Int(g8.x.rounded()), gy = Int(g8.y.rounded())
            var raw = [SIMD2<Float>](repeating: global, count: gw * gh)
            func cost(_ a: UnsafeBufferPointer<Float>, _ c: UnsafeBufferPointer<Float>, _ rw: Int, _ rh: Int,
                      _ x0: Int, _ y0: Int, _ size: Int, _ dx: Int, _ dy: Int) -> Float {
                guard x0 + dx >= 0, y0 + dy >= 0, x0 + size + dx <= rw, y0 + size + dy <= rh else { return .greatestFiniteMagnitude }
                var sum: Float = 0
                for y in y0..<(y0 + size) { let ra = y * rw, rb = (y + dy) * rw + dx
                    for x in x0..<(x0 + size) { sum += abs(a[ra + x] - c[rb + x]) } }
                return sum / Float(size * size)
            }
            func vertex(_ l: Float, _ m: Float, _ r: Float) -> Float {
                let d = l - 2 * m + r
                return d > 0 && d.isFinite ? max(-0.5, min(0.5, (l - r) / (2 * d))) : 0
            }
            coarse.withUnsafeBufferPointer { a8 in b.coarse.withUnsafeBufferPointer { c8 in
            fine.withUnsafeBufferPointer { a4 in b.fine.withUnsafeBufferPointer { c4 in
                for by in 0..<gh { for bx in 0..<gw {
                    var best = (Float.greatestFiniteMagnitude, gx, gy)
                    for dy in (gy - 5)...(gy + 5) { for dx in (gx - 5)...(gx + 5) {
                        let e = cost(a8, c8, cw, ch, bx * 8, by * 8, 8, dx, dy)
                        if e < best.0 { best = (e, dx, dy) }
                    }}
                    let g4 = global / 4
                    let atGlobal = cost(a4, c4, w, h, bx * 16, by * 16, 16, Int(g4.x.rounded()), Int(g4.y.rounded()))
                    var fineCost = [Float](repeating: .greatestFiniteMagnitude, count: 9)
                    for j in 0..<3 { for i in 0..<3 {
                        fineCost[j * 3 + i] = cost(a4, c4, w, h, bx * 16, by * 16, 16, 2 * best.1 + i - 1, 2 * best.2 + j - 1)
                    }}
                    let k = fineCost.indices.min { fineCost[$0] < fineCost[$1] }!
                    guard fineCost[k] < 0.8 * atGlobal, atGlobal - fineCost[k] > 0.002 else { continue }
                    let i = k % 3, j = k / 3
                    let sx = i == 1 ? vertex(fineCost[3], fineCost[4], fineCost[5]) : 0
                    let sy = j == 1 ? vertex(fineCost[1], fineCost[4], fineCost[7]) : 0
                    raw[by * gw + bx] = SIMD2(Float(2 * best.1 + i - 1) + sx, Float(2 * best.2 + j - 1) + sy) * 4
                }}
            }}
            }}
            var out = raw
            for by in 0..<gh { for bx in 0..<gw {
                var xs: [Float] = [], ys: [Float] = []
                for y in max(0, by - 1)...min(gh - 1, by + 1) { for x in max(0, bx - 1)...min(gw - 1, bx + 1) {
                    xs.append(raw[y * gw + x].x); ys.append(raw[y * gw + x].y) } }
                xs.sort(); ys.sort()
                out[by * gw + bx] = SIMD2(xs[xs.count / 2], ys[ys.count / 2])
            }}
            return MotionField(gw: gw, gh: gh, vectors: out)
        }

        /// Mean absolute difference of a(x) and b(x + d) over the inner area, with each side's mean removed.
        private static func sad(_ a: [Float], _ b: [Float], _ w: Int, _ h: Int, _ dx: Int, _ dy: Int, margin: Int) -> Float {
            var ma: Float = 0, mb: Float = 0, n: Float = 0
            let ys = margin..<(h - margin), xs = margin..<(w - margin)
            a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in
                for y in ys { for x in xs { ma += a[y * w + x]; mb += b[(y + dy) * w + x + dx]; n += 1 } }
            }}
            let off = (mb - ma) / n
            var s: Float = 0
            a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { b in
                for y in ys { for x in xs { s += abs(a[y * w + x] + off - b[(y + dy) * w + x + dx]) } }
            }}
            return s / n
        }
    }

    /// Motion per 64 px block, full-resolution pixels, y down.
    struct MotionField: Sendable {
        let gw: Int, gh: Int
        var vectors: [SIMD2<Float>]
        static let block: Float = 64

        /// Bilinear between block centres.
        func at(_ x: Float, _ y: Float) -> SIMD2<Float> {
            let fx = min(Float(gw - 1), max(0, x / Self.block - 0.5)), fy = min(Float(gh - 1), max(0, y / Self.block - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(gw - 1, x0 + 1), y1 = min(gh - 1, y0 + 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let top = vectors[y0 * gw + x0] * (1 - tx) + vectors[y0 * gw + x1] * tx
            let bottom = vectors[y1 * gw + x0] * (1 - tx) + vectors[y1 * gw + x1] * tx
            return top * (1 - ty) + bottom * ty
        }

        static func + (a: MotionField, b: MotionField) -> MotionField {
            MotionField(gw: a.gw, gh: a.gh, vectors: zip(a.vectors, b.vectors).map { $0 + $1 })
        }
        static prefix func - (a: MotionField) -> MotionField { MotionField(gw: a.gw, gh: a.gh, vectors: a.vectors.map { -$0 }) }
    }

    let settings: Settings
    private let context: CIContext
    private let lumaKernel: CIColorKernel
    private let peakKernel: CIKernel
    private let maskKernel: CIKernel
    private let fillKernel: CIKernel
    private var pool: CVPixelBufferPool?
    private var window: [Entry] = []
    private var cursor = 0
    private let previousCount = 1, nextCount = 2

    private struct Entry {
        let image: CIImage
        /// r: spot contrast, g: contrast needed, b: blurred luma.
        let peak: CIImage
        let probe: MotionProbe
        let time: CMTime
        var motionToNext: MotionField?
    }

    /// Returns nil when the Metal kernels fail to compile. The caller then uses frames unchanged.
    init?(context: CIContext, settings: Settings = Settings()) {
        guard let kernels = try? CIKernel.kernels(withMetalString: Self.metalSource),
              let luma = kernels.first(where: { $0.name == "HydroToneSpeckLuma" }) as? CIColorKernel,
              let peak = kernels.first(where: { $0.name == "HydroToneSpeckPeak" }),
              let mask = kernels.first(where: { $0.name == "HydroToneSpeckMask" }),
              let fill = kernels.first(where: { $0.name == "HydroToneSpeckFill" }) else { return nil }
        self.context = context
        self.settings = settings
        lumaKernel = luma; peakKernel = peak; maskKernel = mask; fillKernel = fill
    }

    /// Adds one frame. Returns the frame that is now ready, or nil while the look-ahead fills.
    /// A frame smaller than 64x64 or of another size than the first passes through unchanged.
    func push(_ image: CIImage, at time: CMTime) -> Frame? {
        if let first = window.first, first.image.extent.size != image.extent.size { return Frame(image: image, time: time) }
        guard let entry = prepare(image, at: time) else { return Frame(image: image, time: time) }
        if let last = window.indices.last {
            let a = window[last].probe
            window[last].motionToNext = a.field(to: entry.probe, global: a.shift(to: entry.probe))
        }
        window.append(entry)
        guard window.count - cursor > nextCount else { return nil }
        return emit()
    }

    /// Flushes the look-ahead. Call once after the last `push`.
    func finish() -> [Frame] {
        var frames: [Frame] = []
        while cursor < window.count { frames.append(emit()) }
        window.removeAll(); cursor = 0
        return frames
    }

    private func emit() -> Frame {
        let source = window[cursor]
        var neighbours: [(CIImage, MotionField)] = []
        if cursor > 0, let m = window[cursor - 1].motionToNext { neighbours.append((window[cursor - 1].peak, -m)) }
        var chained: MotionField?
        for i in (cursor + 1)..<min(window.count, cursor + 1 + nextCount) {
            guard let step = window[i - 1].motionToNext else { break }
            chained = chained.map { $0 + step } ?? step
            neighbours.append((window[i].peak, chained!))
        }
        let output = filtered(source, neighbours: neighbours)
        cursor += 1
        let drop = max(0, cursor - previousCount)
        if drop > 0 { window.removeFirst(drop); cursor -= drop }
        return Frame(image: output, time: source.time)
    }

    private func filtered(_ source: Entry, neighbours: [(CIImage, MotionField)]) -> CIImage {
        guard !neighbours.isEmpty else { return source.image }
        let s = settings
        let extent = source.image.extent
        let empty = CIImage(color: .clear).cropped(to: extent)
        var peaks = neighbours.map { $0.0.clampedToExtent() }
        var fields = neighbours.map(\.1)
        while peaks.count < 3 { peaks.append(empty); fields.append(fields[0]) }
        let flowA = flowImage(fields[0], fields[1], extent: extent), flowB = flowImage(fields[2], fields[2], extent: extent)
        let reach = CGFloat(2 * s.contextRadius + 6)
        guard let mask = maskKernel.apply(extent: extent, roiCallback: { i, r in
                  (i == 0 || i >= 4) ? r.insetBy(dx: -reach, dy: -reach) : r.insetBy(dx: -reach - 256, dy: -reach - 256) },
                  arguments: [source.peak.clampedToExtent(), peaks[0], peaks[1], peaks[2], flowA, flowB,
                              CIVector(x: CGFloat(neighbours.count), y: CGFloat(s.matchRatio),
                                       z: CGFloat(s.contextRadius), w: CGFloat(s.contextTolerance)),
                              CIVector(x: CGFloat(s.floor), y: 0, z: 0, w: 0)]),
              let out = fillKernel.apply(extent: extent, roiCallback: { _, r in
                  r.insetBy(dx: CGFloat(-s.fillRadius - 2), dy: CGFloat(-s.fillRadius - 2)) },
                  arguments: [source.image.clampedToExtent(), mask.clampedToExtent(), CIVector(x: CGFloat(s.fillRadius), y: 0, z: 0, w: 0)])
        else { return source.image }
        return out.cropped(to: extent)
    }

    /// Two motion fields as one small image, bilinear between block centres, in Core Image axes (y up).
    private func flowImage(_ a: MotionField, _ b: MotionField, extent: CGRect) -> CIImage {
        var values = [Float](repeating: 0, count: a.gw * a.gh * 4)
        for row in 0..<a.gh { for x in 0..<a.gw {
            let src = row * a.gw + x, dst = ((a.gh - 1 - row) * a.gw + x) * 4
            values[dst] = a.vectors[src].x; values[dst + 1] = -a.vectors[src].y
            values[dst + 2] = b.vectors[src].x; values[dst + 3] = -b.vectors[src].y
        }}
        let data = values.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: a.gw * 16, size: CGSize(width: a.gw, height: a.gh),
                            format: .RGBAf, colorSpace: nil)
        // The blocks cover whole 64 px cells from the top. Core Image rows start at the bottom.
        let top = extent.maxY, covered = CGFloat(a.gh) * CGFloat(MotionField.block)
        return image.samplingLinear().clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(MotionField.block), y: CGFloat(MotionField.block)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: top - covered))
    }

    /// Renders the peak map (kept for up to 4 frames) and the 1/4-scale luma probe for this frame.
    private func prepare(_ image: CIImage, at time: CMTime) -> Entry? {
        let extent = image.extent
        let w = Int(extent.width), h = Int(extent.height)
        guard w >= 64, h >= 64, let luma = lumaKernel.apply(extent: extent, arguments: [image]) else { return nil }
        let blurred = luma.clampedToExtent().applyingGaussianBlur(sigma: 0.8)
        let s = settings
        guard let peakRecipe = peakKernel.apply(extent: extent, roiCallback: { _, r in
                  r.insetBy(dx: CGFloat(-s.ringRadius - 2), dy: CGFloat(-s.ringRadius - 2)) },
                  arguments: [blurred, CIVector(x: CGFloat(s.ringRadius), y: CGFloat(s.floor), z: CGFloat(s.spreadGain),
                                                w: CGFloat(s.maxContrast))]),
              let buffer = peakBuffer(width: w, height: h) else { return nil }
        context.render(peakRecipe.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
                       to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
        let peak = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let qw = w / 4, qh = h / 4
        var quarter = [Float](repeating: 0, count: qw * qh)
        let small = luma.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .scaledBy(x: CGFloat(qw) / CGFloat(w), y: CGFloat(qh) / CGFloat(h)), highQualityDownsample: true)
        quarter.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: qw * 4,
                           bounds: CGRect(x: 0, y: 0, width: qw, height: qh), format: .Rf, colorSpace: nil)
        }
        return Entry(image: image, peak: peak, probe: MotionProbe(quarter: quarter, width: qw, height: qh), time: time)
    }

    private func peakBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                                             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                             kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        return buffer
    }

    private static let metalSource = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    constant float2 ring16[16] = {
        float2(1.0f, 0.0f), float2(0.9239f, 0.3827f), float2(0.7071f, 0.7071f), float2(0.3827f, 0.9239f),
        float2(0.0f, 1.0f), float2(-0.3827f, 0.9239f), float2(-0.7071f, 0.7071f), float2(-0.9239f, 0.3827f),
        float2(-1.0f, 0.0f), float2(-0.9239f, -0.3827f), float2(-0.7071f, -0.7071f), float2(-0.3827f, -0.9239f),
        float2(0.0f, -1.0f), float2(0.3827f, -0.9239f), float2(0.7071f, -0.7071f), float2(0.9239f, -0.3827f)
    };

    // Perceptual luma: square root of linear Rec. 709 luma, so thresholds act alike in dark and bright water.
    [[stitchable]] float4 HydroToneSpeckLuma(coreimage::sample_t s) {
        const float l = sqrt(max(dot(s.rgb, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f));
        return float4(l, l, l, 1.0f);
    }

    // r: centre minus the brightest ring point. g: contrast a spot needs here. b: blurred luma.
    // p = (ring radius, floor, spread gain, max contrast).
    [[stitchable]] float4 HydroToneSpeckPeak(coreimage::sampler lum, float4 p, coreimage::destination dest) {
        const float2 c = dest.coord();
        const float centre = lum.sample(lum.transform(c)).r;
        float hi = -1.0e4f, lo = 1.0e4f, sum = 0.0f;
        for (int i = 0; i < 16; i++) {
            const float v = lum.sample(lum.transform(c + p.x * ring16[i])).r;
            hi = max(hi, v); lo = min(lo, v); sum += v;
        }
        // A very bright spot (contrast over the ring mean above p.w) gets an unreachable threshold.
        const float need = centre - sum / 16.0f > p.w ? 1.0e4f : max(p.y, p.z * (hi - lo));
        return float4(centre - hi, need, centre, 1.0f);
    }

    // 0: neighbour not usable (the area around the spot changed), 1: spot found there, 2: spot gone.
    static int look(coreimage::sampler cur, coreimage::sampler n, float2 at, float2 flow, float4 v, float4 q, float floorLevel) {
        float diff = 0.0f;
        for (int i = 0; i < 32; i++) {
            const float2 r = (i < 16 ? q.z : 2.0f * q.z) * ring16[i % 16];
            diff += abs(cur.sample(cur.transform(at + r)).b - n.sample(n.transform(at + flow + r)).b);
        }
        if (diff / 32.0f > q.w * v.r + 0.5f * floorLevel) { return 0; }
        const float need = max(v.r * q.y, 0.5f * v.g);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (n.sample(n.transform(at + flow + float2(dx, dy))).r >= need) { return 1; }
            }
        }
        return 2;
    }

    // r: how strongly this pixel belongs to a drifting spot, 0...1. A spot centre within 4 px marks it,
    // so the camera's dark sharpening halo around a speck is covered too.
    // q = (neighbour count, match ratio, context radius, context tolerance). q2.x = floor.
    [[stitchable]] float4 HydroToneSpeckMask(coreimage::sampler cur, coreimage::sampler n0, coreimage::sampler n1,
                                             coreimage::sampler n2, coreimage::sampler flowA, coreimage::sampler flowB,
                                             float4 q, float4 q2, coreimage::destination dest) {
        const float2 c = dest.coord();
        const int count = int(q.x);
        float best = 0.0f;
        for (int dy = -4; dy <= 4; dy++) {
            for (int dx = -4; dx <= 4; dx++) {
                const float2 o = c + float2(dx, dy);
                const float4 v = cur.sample(cur.transform(o));
                if (v.r <= v.g) { continue; }
                const float4 fa = flowA.sample(flowA.transform(o));
                const float2 fb = flowB.sample(flowB.transform(o)).rg;
                bool gone = look(cur, n0, o, fa.rg, v, q, q2.x) == 2;
                if (!gone && count > 1) { gone = look(cur, n1, o, fa.ba, v, q, q2.x) == 2; }
                if (!gone && count > 2) { gone = look(cur, n2, o, fb, v, q, q2.x) == 2; }
                if (!gone) { continue; }
                const float strength = smoothstep(v.g, 2.0f * v.g, v.r);
                const float reach = clamp(4.5f - length(float2(dx, dy)), 0.0f, 1.0f);
                best = max(best, max(strength, 0.5f) * reach);
            }
        }
        return float4(best, best, best, 1.0f);
    }

    // Replaces marked pixels with the mean of the unmarked ring pixels (the local background).
    [[stitchable]] float4 HydroToneSpeckFill(coreimage::sampler src, coreimage::sampler mask, float4 p,
                                             coreimage::destination dest) {
        const float2 c = dest.coord();
        const float4 s = src.sample(src.transform(c));
        const float m = mask.sample(mask.transform(c)).r;
        if (m <= 0.0f) { return s; }
        float3 sum = float3(0.0f);
        float n = 0.0f;
        for (int i = 0; i < 16; i++) {
            const float2 at = c + p.x * ring16[i];
            if (mask.sample(mask.transform(at)).r > 0.0f) { continue; }
            sum += src.sample(src.transform(at)).rgb;
            n += 1.0f;
        }
        if (n < 4.0f) { return s; }
        return float4(mix(s.rgb, sum / n, m), s.a);
    }
    """
}
