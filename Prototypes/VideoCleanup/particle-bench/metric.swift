// Particle metric on 8-bit luma (CPU, independent of the GPU filter code except the shared MotionProbe).
//
// Residual R = 3x3-mean luma minus 17x17-mean luma. Local noise = 1.25 * mean |Y - 3x3 mean| per 32x32 tile,
// divided by 3 because the 3x3 mean cuts pixel noise by 3.
// Group: connected pixels (8-neighbour) with R above half of T, whose peak R is above T.
// T = max(k * local noise, floor). floor = 4 levels: fainter bumps were not visible in the checked crops.
// Size: half-max area = pixels of the group where (Y - 17x17 mean) >= half of its peak.
// Isolated: on a ring 3 px outside the half-max disc (16 points of the 3x3 mean), max - min is below half the peak.
// A highlight on a fish, or a grain in busy texture, fails this test.
// Speck: isolated bright group with size 1...12 px. Soft dot: isolated bright group, size 13...40 px.
// Peak above 30 levels: "bright spot", not counted as a particle. In every gallery checked, such spots were
// coral tips, fish highlights or anemone tips. Real specks in these clips peaked at 4...16 levels.
// Drifting speck: a speck with no match in frame t-1 OR in frame t+2 after camera motion is removed
// (global shift, then local motion per 64 px block, measured directly between the two frames).
// A neighbour counts only when the area around the speck matches there: the mean |3x3 mean difference| on a
// ring (half-max disc radius + 4 px) and a ring at 12 px (32 points) is below 0.03 * peak + 0.5 * T. A spot on a moving fish fails this, so it is
// not counted as a particle. Drifting = in a usable neighbour, no residual >= max(0.08 * peak, T / 2) within 2 px.
// Small subject: a group of 13...2000 px, brighter or darker than the background by T. Preservation is
// the sum of |residual| inside the ORIGINAL frame's small-subject pixels, variant over original.
import Foundation

struct MetricSettings: Sendable {
    var k: Float = 5
    var floor: Float = 4
    var maxDotArea = 40
    /// Spots brighter than this above their background are counted as "bright spots", not particles.
    var maxPeak: Float = 30
    var maxSpeckArea = 12
    var maxSubjectArea = 2000
    var matchRatio: Float = 0.08
    var matchRadius = 2
}

struct Blob { let area: Int; let size: Int; let isolated: Bool; let cx: Float; let cy: Float; let peak: Float; let x0, y0, x1, y1: Int }

/// Everything the metric needs from one frame.
struct FrameMaps {
    let w: Int, h: Int
    let y: [Float]
    let s3: [Float]
    let residual: [Float]    // 3x3 mean - 17x17 mean
    let threshold: [Float]   // per tile T, expanded per pixel is too big; kept per tile
    let tiles: Int
    let bright: [Blob]       // all bright groups (any size up to maxSubjectArea)
    let dark: [Blob]

    func t(_ x: Int, _ y: Int) -> Float { threshold[(y / 32) * tiles + x / 32] }
}

func maps(_ y: [Float], _ w: Int, _ h: Int, _ m: MetricSettings) -> FrameMaps {
    let s3 = boxBlur(y, w, h, radius: 1)
    let s17 = boxBlur(y, w, h, radius: 8)
    var r = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { r[i] = s3[i] - s17[i] }
    let tw = (w + 31) / 32, th = (h + 31) / 32
    var sum = [Float](repeating: 0, count: tw * th), cnt = [Float](repeating: 0, count: tw * th)
    for yy in 0..<h { for xx in 0..<w { let t = (yy / 32) * tw + xx / 32; sum[t] += abs(y[yy * w + xx] - s3[yy * w + xx]); cnt[t] += 1 } }
    let thr = (0..<(tw * th)).map { max(m.k * 1.25 * sum[$0] / max(1, cnt[$0]) / 3, m.floor) }
    func blobs(sign: Float) -> [Blob] {
        var mark = [UInt8](repeating: 0, count: w * h)
        for yy in 0..<h { for xx in 0..<w { let i = yy * w + xx; if sign * r[i] > 0.5 * thr[(yy / 32) * tw + xx / 32] { mark[i] = 1 } } }
        var out: [Blob] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mark[start] == 1 {
            mark[start] = 2; stack = [start]
            var area = 0, sx: Float = 0, sy: Float = 0, sw: Float = 0, peak: Float = 0
            var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
            var big = false
            var members: [Int] = []
            var rawPeak: Float = 0
            while let i = stack.popLast() {
                members.append(i)
                rawPeak = max(rawPeak, sign * (y[i] - s17[i]))
                let xx = i % w, yy = i / w
                area += 1
                if area > m.maxSubjectArea { big = true }
                let v = sign * r[i]
                sx += Float(xx) * v; sy += Float(yy) * v; sw += v; peak = max(peak, v)
                x0 = min(x0, xx); y0 = min(y0, yy); x1 = max(x1, xx); y1 = max(y1, yy)
                for dy in -1...1 { for dx in -1...1 {
                    let nx = xx + dx, ny = yy + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if mark[j] == 1 { mark[j] = 2; stack.append(j) }
                }}
            }
            let cxi = Int(sx / max(sw, 1e-6)), cyi = Int(sy / max(sw, 1e-6))
            guard !big, peak > thr[(min(h - 1, max(0, cyi)) / 32) * tw + min(w - 1, max(0, cxi)) / 32] else { continue }
            let size = members.reduce(0) { $0 + (sign * (y[$1] - s17[$1]) >= rawPeak / 2 ? 1 : 0) }
            let radius = (Float(size) / .pi).squareRoot() + 3
            var hi = -Float.greatestFiniteMagnitude, lo = Float.greatestFiniteMagnitude
            for k in 0..<16 {
                let a = Float(k) * .pi / 8
                let rx = min(w - 1, max(0, Int((sx / sw + radius * cos(a)).rounded()))), ry = min(h - 1, max(0, Int((sy / sw + radius * sin(a)).rounded())))
                hi = max(hi, s3[ry * w + rx]); lo = min(lo, s3[ry * w + rx])
            }
            do { out.append(Blob(area: area, size: size, isolated: hi - lo < 0.5 * peak, cx: sx / sw, cy: sy / sw, peak: peak, x0: x0, y0: y0, x1: x1, y1: y1)) }
        }
        return out
    }
    return FrameMaps(w: w, h: h, y: y, s3: s3, residual: r, threshold: thr, tiles: tw, bright: blobs(sign: 1), dark: blobs(sign: -1))
}

nonisolated(unsafe) var debugLook = false
enum Look { case unusable, found, gone }

/// Compares blob `b` of frame `f` with frame `n`, where the camera moved the blob centre by `v`.
func look(_ f: FrameMaps, _ b: Blob, _ n: FrameMaps, _ v: SIMD2<Float>, _ m: MetricSettings) -> Look {
    let radius = (Float(b.size) / .pi).squareRoot() + 4
    var diff: Float = 0
    for k in 0..<32 {
        let a = Float(k % 16) * .pi / 8, r = k < 16 ? radius : max(radius, 12)
        let px = b.cx + r * cos(a), py = b.cy + r * sin(a)
        let ax = min(f.w - 1, max(0, Int(px.rounded()))), ay = min(f.h - 1, max(0, Int(py.rounded())))
        let bx = min(n.w - 1, max(0, Int((px + v.x).rounded()))), by = min(n.h - 1, max(0, Int((py + v.y).rounded())))
        diff += abs(f.s3[ay * f.w + ax] - n.s3[by * n.w + bx])
    }
    let t = f.t(min(f.w - 1, max(0, Int(b.cx))), min(f.h - 1, max(0, Int(b.cy))))
    if debugLook {
        var bestR: Float = -99
        let cx = Int((b.cx + v.x).rounded()), cy = Int((b.cy + v.y).rounded())
        for dy in -2...2 { for dx in -2...2 { let xx = cx + dx, yy = cy + dy
            if xx >= 0, yy >= 0, xx < n.w, yy < n.h { bestR = max(bestR, n.residual[yy * n.w + xx]) } } }
        print(String(format: "    peak %.1f T %.1f ringDiff %.1f tol %.1f bestR %.1f need %.1f Tn %.1f v (%.1f,%.1f)", b.peak, t, diff / 32, 0.03 * b.peak + 0.5 * t, bestR, b.peak * m.matchRatio, n.t(min(n.w - 1, max(0, cx)), min(n.h - 1, max(0, cy))), v.x, v.y))
    }
    if diff / 32 > 0.03 * b.peak + 0.5 * t { return .unusable }
    return matched(n, x: b.cx + v.x, y: b.cy + v.y, need: b.peak * m.matchRatio, m) ? .found : .gone
}

/// True when frame `n` has a bright residual near `p` (already moved by the camera shift).
func matched(_ n: FrameMaps, x: Float, y: Float, need: Float, _ m: MetricSettings) -> Bool {
    let cx = Int(x.rounded()), cy = Int(y.rounded())
    for dy in -m.matchRadius...m.matchRadius { for dx in -m.matchRadius...m.matchRadius {
        let xx = cx + dx, yy = cy + dy
        guard xx >= 0, yy >= 0, xx < n.w, yy < n.h else { continue }
        let v = n.residual[yy * n.w + xx]
        if v >= need && v >= 0.5 * n.t(xx, yy) { return true }
    }}
    return false
}

struct SpeckCount { var brightSpots = 0; var all = 0; var drifting = 0; var staticCount = 0; var attached = 0; var driftingBlobs: [Blob] = []; var dots = 0; var driftingDots = 0 }

/// `prev` and `next2` with the motion that maps a point in this frame to that frame.
func specks(_ f: FrameMaps, prev: (FrameMaps, ParticleFilterV1.MotionField)?, next2: (FrameMaps, ParticleFilterV1.MotionField)?, _ m: MetricSettings) -> SpeckCount {
    var c = SpeckCount()
    for b in f.bright where b.size <= m.maxDotArea && b.isolated {
        if b.peak > m.maxPeak { c.brightSpots += 1; continue }
        let dot = b.size > m.maxSpeckArea
        if dot { c.dots += 1 } else { c.all += 1 }
        let looks = [prev, next2].compactMap { $0 }.map { look(f, b, $0.0, $0.1.at(b.cx, b.cy), m) }
        if !looks.contains(.gone) && !looks.contains(.found) { if !dot { c.attached += 1 }; continue }
        if looks.contains(.gone) {
            if dot { c.driftingDots += 1 } else { c.drifting += 1; c.driftingBlobs.append(b) }
        } else if !dot { c.staticCount += 1 }
    }
    return c
}

/// Pixel mask of the original frame's small subjects: bright groups above maxDotArea, dark groups above
/// maxSpeckArea, both up to maxSubjectArea pixels.
func subjectMask(_ f: FrameMaps, _ m: MetricSettings) -> [Int] {
    var idx: [Int] = []
    for b in f.bright.filter({ $0.size > m.maxDotArea }) + f.dark.filter({ $0.size > m.maxSpeckArea }) {
        for yy in b.y0...b.y1 { for xx in b.x0...b.x1 {
            let i = yy * f.w + xx
            if abs(f.residual[i]) > f.t(xx, yy) { idx.append(i) }
        }}
    }
    return idx
}

/// Pixel mask of the original frame's small DARK groups (1 ... maxSpeckArea): distant dark fish, fish eyes.
func darkSmallMask(_ f: FrameMaps, _ m: MetricSettings) -> [Int] {
    var idx: [Int] = []
    for b in f.dark where b.size <= m.maxSpeckArea {
        for yy in b.y0...b.y1 { for xx in b.x0...b.x1 { let i = yy * f.w + xx; if -f.residual[i] > f.t(xx, yy) { idx.append(i) } } }
    }
    return idx
}

/// Motion probe from full-resolution 8-bit luma, same scale and shape the filter uses.
func probe(_ y: [Float], _ w: Int, _ h: Int) -> ParticleFilterV1.MotionProbe {
    let (q, qw, qh) = downsample(y.map { ($0 / 255).squareRoot() }, w, h, by: 4)
    return ParticleFilterV1.MotionProbe(quarter: q, width: qw, height: qh)
}

/// Camera motion from frame a to frame b: global shift, then per-block refinement.
func motion(_ a: [Float], _ b: [Float], _ w: Int, _ h: Int) -> ParticleFilterV1.MotionField {
    let pa = probe(a, w, h), pb = probe(b, w, h)
    return pa.field(to: pb, global: pa.shift(to: pb))
}
