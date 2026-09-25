// Mode "run <tag> <clip> <start> <seconds>": quality of every variant on one segment, plus crops.
// Mode "speed <clip> <start>": fps of every variant on 120 preloaded frames.
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

// Every variant is scored after ONE Core Image render into 420v, the same path the export uses.
// A Core Image read+write alone adds about +1.9 luma levels (mode "roundtrip"), so the raw decode is not the baseline.
let variantNames = ["a original", "b denoise 0.5", "c particle", "d denoise>particle", "e particle>denoise"]
let V = 5

/// Renders Core Image output into plain 420v (for luma) with the source's colour tags.
final class Renderer {
    let ctx: CIContext
    let transfer: VTPixelTransferSession
    init(_ ctx: CIContext) {
        self.ctx = ctx
        var s: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
        transfer = s!
    }
    func buffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        return b!
    }
    func render(_ image: CIImage, like source: CVPixelBuffer) -> CVPixelBuffer {
        let out = buffer(CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVBufferPropagateAttachments(source, out)
        ctx.render(image, to: out, bounds: image.extent, colorSpace: CIImage(cvPixelBuffer: source).colorSpace)
        return out
    }
    /// 420v -> the denoiser's compressed format.
    func compressed(_ b: CVPixelBuffer) -> CVPixelBuffer {
        let out = buffer(CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b), TemporalDenoiser.sourcePixelFormat(hdr: false))
        VTPixelTransferSessionTransferImage(transfer, from: b, to: out)
        CVBufferPropagateAttachments(b, out)
        return out
    }
}

struct VariantSums {
    var drift = 0, dots = 0, statics = 0, bright = 0, frames = 0
    var removedOfOriginal = 0, originalDrift = 0
    var subj = 0.0, subjRef = 0.0, darkSmall = 0.0, darkSmallRef = 0.0
    var sharp = 0.0, sharpRef = 0.0
    var changed = 0.0, meanAbs = 0.0
}

/// Mean squared gradient of the 3x3 mean in the top-25% texture blocks (16x16) of the original frame.
func texturedBlocks(_ s3: [Float], _ w: Int, _ h: Int) -> [Int] {
    let gw = w / 16, gh = h / 16
    var t = [Float](repeating: 0, count: gw * gh)
    for by in 0..<gh { for bx in 0..<gw {
        var s: Float = 0
        for y in (by * 16)..<(by * 16 + 16) where y + 1 < h { for x in (bx * 16)..<(bx * 16 + 16) where x + 1 < w {
            let i = y * w + x, dx = s3[i + 1] - s3[i], dy = s3[i + w] - s3[i]; s += dx * dx + dy * dy } }
        t[by * gw + bx] = s
    }}
    let q75 = t.sorted()[t.count * 3 / 4]
    return t.indices.filter { t[$0] >= q75 }
}

func gradientEnergy(_ s3: [Float], _ blocks: [Int], _ w: Int, _ h: Int) -> Double {
    let gw = w / 16
    var s = 0.0
    for b in blocks {
        let bx = b % gw, by = b / gw
        for y in (by * 16)..<(by * 16 + 16) where y + 1 < h { for x in (bx * 16)..<(bx * 16 + 16) where x + 1 < w {
            let i = y * w + x, dx = Double(s3[i + 1] - s3[i]), dy = Double(s3[i + w] - s3[i]); s += dx * dx + dy * dy } }
    }
    return s
}

func runSegment(_ tag: String, _ clip: String, _ start: Double, _ seconds: Double, fish fishWindow: (Int, Int)? = nil) async throws {
    let path = fixtures + clipFiles[clip]!
    let reader = try await Reader(path, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: seconds)
    let ctx = CIContext()
    let r = Renderer(ctx)
    let m = MetricSettings()
    var luma: Luma?
    var w = 0, h = 0
    var denB: TemporalDenoiser?, denD: TemporalDenoiser?, denE: TemporalDenoiser?
    let pfC = ParticleFilter(context: ctx)!, pfD = ParticleFilter(context: ctx)!, pfE = ParticleFilter(context: ctx)!
    var sources: [CMTime: (Int, CVPixelBuffer)] = [:]
    var lumas = [[Int: [Float]]](repeating: [:], count: V)
    var fmaps = [[Int: FrameMaps]](repeating: [:], count: V)
    var rgbCrop = [RGBA?](repeating: nil, count: V)
    var outCount = [Int](repeating: 0, count: V)
    var sums = [VariantSums](repeating: VariantSums(), count: V)
    var total = 0
    var cropIndex = -1
    var processed = 1
    var cropBlobs: [Blob] = []
    var cropMaps: FrameMaps?
    var cropFish: [Blob] = []

    func accept(_ v: Int, _ buffer: CVPixelBuffer, _ time: CMTime) throws {
        guard let (i, src) = sources[time] else { fatalError("unknown time") }
        let scored = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ? buffer : r.render(CIImage(cvPixelBuffer: buffer), like: src)
        lumas[v][i] = try luma!.read(scored)
        outCount[v] += 1
        if i == cropIndex { rgbCrop[v] = renderRGBA(CIImage(cvPixelBuffer: buffer), ctx) }
    }
    func mapsFor(_ v: Int, _ i: Int) -> FrameMaps {
        if let f = fmaps[v][i] { return f }
        let f = maps(lumas[v][i]!, w, h, m); fmaps[v][i] = f; return f
    }
    func process(_ k: Int) {
        let yo = lumas[0][k]!
        let mp = motion(yo, lumas[0][k - 1]!, w, h), mn = motion(yo, lumas[0][k + 2]!, w, h)
        let fo = mapsFor(0, k)
        let orig = specks(fo, prev: (mapsFor(0, k - 1), mp), next2: (mapsFor(0, k + 2), mn), m)
        let subject = subjectMask(fo, m), dark = darkSmallMask(fo, m)
        let blocks = texturedBlocks(fo.s3, w, h)
        let sharpRef = gradientEnergy(fo.s3, blocks, w, h)
        if k == cropIndex {
            cropBlobs = orig.driftingBlobs; cropMaps = fo
            // Persistent dark objects: a dark group in this frame with a dark group within 6 px of the same
            // place (camera motion removed) in the previous frame. Noise rarely repeats; fish do.
            let before = mapsFor(0, k - 1).dark
            cropFish = fo.dark.filter { b in
                let v = mp.at(b.cx, b.cy), x = b.cx + v.x, y = b.cy + v.y
                return b.size >= 2 && before.contains { abs($0.cx - x) < 6 && abs($0.cy - y) < 6 }
            }
        }
        for v in 0..<V {
            let f = mapsFor(v, k)
            let c = v == 0 ? orig : specks(f, prev: (mapsFor(v, k - 1), mp), next2: (mapsFor(v, k + 2), mn), m)
            sums[v].frames += 1; sums[v].drift += c.drifting; sums[v].dots += c.driftingDots
            sums[v].statics += c.staticCount; sums[v].bright += c.brightSpots
            sums[v].originalDrift += orig.drifting
            for b in orig.driftingBlobs {
                let x = Int(b.cx.rounded()), y = Int(b.cy.rounded())
                var best: Float = -99
                for dy in -1...1 { for dx in -1...1 { let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < w, yy < h { best = max(best, f.residual[yy * w + xx]) } } }
                if best < 0.5 * b.peak { sums[v].removedOfOriginal += 1 }
            }
            for i in subject { sums[v].subj += Double(abs(f.residual[i])); sums[v].subjRef += Double(abs(fo.residual[i])) }
            for i in dark { sums[v].darkSmall += Double(abs(f.residual[i])); sums[v].darkSmallRef += Double(abs(fo.residual[i])) }
            sums[v].sharp += gradientEnergy(f.s3, blocks, w, h); sums[v].sharpRef += sharpRef
            var ch = 0, ma = 0.0
            let yv = lumas[v][k]!
            for i in 0..<(w * h) { let d = abs(yv[i] - yo[i]); if d > 2 { ch += 1 }; ma += Double(d) }
            sums[v].changed += Double(ch) / Double(w * h); sums[v].meanAbs += ma / Double(w * h)
        }
        for v in 0..<V { fmaps[v][k - 1] = nil; lumas[v][k - 1] = nil }
    }
    func drain(final: Bool) {
        while true {
            let k = processed
            guard lumas.allSatisfy({ $0[k + 2] != nil && $0[k - 1] != nil && $0[k] != nil }) else { break }
            process(k); processed += 1
        }
    }

    let t0 = Date()
    while let (buffer, time) = reader.next() {
        if luma == nil {
            w = CVPixelBufferGetWidth(buffer); h = CVPixelBufferGetHeight(buffer)
            luma = Luma(width: w, height: h)
            denB = TemporalDenoiser(width: w, height: h, hdr: false, strength: 0.5)
            denD = TemporalDenoiser(width: w, height: h, hdr: false, strength: 0.5)
            denE = TemporalDenoiser(width: w, height: h, hdr: false, strength: 0.5)
            cropIndex = Int(seconds * 59.94 / 2)
        }
        sources[time] = (total, buffer)
        total += 1
        let src = CIImage(cvPixelBuffer: buffer)
        try accept(0, buffer, time)
        if let o = await denB!.push(buffer, at: time) { try accept(1, o.buffer, o.time) }
        if let o = pfC.push(src, at: time) { try accept(2, r.render(o.image, like: sources[o.time]!.1), o.time) }
        if let o = await denD!.push(buffer, at: time), let p = pfD.push(CIImage(cvPixelBuffer: o.buffer), at: o.time) {
            try accept(3, r.render(p.image, like: sources[p.time]!.1), p.time)
        }
        if let p = pfE.push(src, at: time) {
            let rendered = r.compressed(r.render(p.image, like: sources[p.time]!.1))
            if let o = await denE!.push(rendered, at: p.time) { try accept(4, o.buffer, o.time) }
        }
        drain(final: false)
        // Keep only the sources the chains may still need.
        for (t, v) in sources where v.0 < total - 8 && v.0 != cropIndex { sources[t] = nil }
    }
    for o in await denB!.finish() { try accept(1, o.buffer, o.time) }
    for o in pfC.finish() { try accept(2, r.render(o.image, like: sources[o.time]!.1), o.time) }
    for o in await denD!.finish() { if let p = pfD.push(CIImage(cvPixelBuffer: o.buffer), at: o.time) { try accept(3, r.render(p.image, like: sources[p.time]!.1), p.time) } }
    for p in pfD.finish() { try accept(3, r.render(p.image, like: sources[p.time]!.1), p.time) }
    for p in pfE.finish() {
        if let o = await denE!.push(r.compressed(r.render(p.image, like: sources[p.time]!.1)), at: p.time) { try accept(4, o.buffer, o.time) }
    }
    for o in await denE!.finish() { try accept(4, o.buffer, o.time) }
    drain(final: true)
    let elapsed = Date().timeIntervalSince(t0)

    print("== \(tag) \(clip) \(start)-\(start + seconds) s: frames in \(total), out per variant \(outCount), scored frames \(sums[0].frames), wall \(f2(elapsed)) s")
    print("   failures: denoise \([denB, denD, denE].map { $0?.failure.map { "\($0)" } ?? "none" })")
    let base = sums[0]
    for (v, s) in sums.enumerated() {
        let n = Double(max(1, s.frames))
        print(String(format: "   %-20@ drift/frame %6.2f (%@) dots/frame %6.2f (%@) static/frame %6.2f bright/frame %5.2f removedOfOrig %5.1f%% subj %6.1f%% darkSmall %6.1f%% sharp %@ changed>2 %6.3f%% meanAbs %5.3f",
                     variantNames[v] as NSString, Double(s.drift) / n, pct(Double(s.drift), Double(base.drift)) as NSString,
                     Double(s.dots) / n, pct(Double(s.dots), Double(base.dots)) as NSString, Double(s.statics) / n, Double(s.bright) / n,
                     100 * Double(s.removedOfOriginal) / Double(max(1, s.originalDrift)),
                     100 * s.subj / max(1e-9, s.subjRef), 100 * s.darkSmall / max(1e-9, s.darkSmallRef),
                     pct(s.sharp, s.sharpRef) as NSString, 100 * s.changed / n, s.meanAbs / n))
    }
    saveCrops(tag, rgbCrop.map { $0! }, cropBlobs, cropMaps!, w, h, fish: fishWindow)
    saveFishCrops(tag, rgbCrop.map { $0! }, cropFish, w, h, handPicked: fishWindow)
}

/// Three windows at the middle frame: most original drifting specks, most small-subject pixels, most texture.
/// `fish` overrides the fish window with a hand-picked one.
func saveCrops(_ tag: String, _ imgs: [RGBA], _ blobs: [Blob], _ f: FrameMaps, _ w: Int, _ h: Int, fish handPicked: (Int, Int)? = nil) {
    let cw = 160, ch = 90
    func best(_ score: (Int, Int) -> Double) -> (Int, Int) {
        var top = (-1.0, 0, 0)
        for y in stride(from: 0, through: h - ch, by: 16) { for x in stride(from: 0, through: w - cw, by: 16) {
            let s = score(x, y); if s > top.0 { top = (s, x, y) } } }
        return (top.1, top.2)
    }
    let speck = best { x, y in Double(blobs.filter { Int($0.cx) >= x && Int($0.cx) < x + cw && Int($0.cy) >= y && Int($0.cy) < y + ch }.count) }
    let subjectPixels = Set(subjectMask(f, MetricSettings()) + darkSmallMask(f, MetricSettings()))
    let fish = handPicked ?? best { x, y in
        var n = 0
        for yy in stride(from: y, to: y + ch, by: 2) { for xx in stride(from: x, to: x + cw, by: 2) where subjectPixels.contains(yy * w + xx) { n += 1 } }
        return Double(n)
    }
    let texture = best { x, y in
        var s = 0.0
        for yy in stride(from: y, to: y + ch, by: 2) { for xx in stride(from: x, to: x + cw - 1, by: 2) { let i = yy * w + xx; s += Double(abs(f.s3[i + 1] - f.s3[i])) } }
        return s
    }
    for (name, (x, y)) in [("specks", speck), ("fish", fish), ("texture", texture)] {
        let c = imgs.map { crop($0, x: x, y: y, w: cw, h: ch, scale: 3, stretch: name == "specks" ? 2 : 1) }
        let plain = imgs.map { crop($0, x: x, y: y, w: cw, h: ch, scale: 3) }
        let d = (0..<V).map { diffImage(plain[0], plain[$0], gain: 4) }
        // Row 1: a | b | c. Row 2: d | e | (blank). Row 3: diff x4 vs a of b | c | d. Row 4: diff x4 vs a of e.
        savePNG(grid([[c[0], c[1], c[2]], [c[3], c[4]], [d[1], d[2], d[3]], [d[4]]]),
                "\(root)/crops2/\(tag)_\(name).png")
        print("   crop \(name): x \(x) y \(y) (160x90 at 3x)")
    }
}

func speedTest(_ clip: String, _ start: Double, size: (Int, Int)? = nil) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 3, size: size)
    var frames: [(CVPixelBuffer, CMTime)] = []
    while frames.count < 120, let f = reader.next() { frames.append(f) }
    reader.reader.cancelReading()
    let w = CVPixelBufferGetWidth(frames[0].0), h = CVPixelBufferGetHeight(frames[0].0)
    let ctx = CIContext()
    let r = Renderer(ctx)
    let lookup = Dictionary(uniqueKeysWithValues: frames.map { ($0.1, $0.0) })
    // Every loop drains an autorelease pool per frame: a render keeps each input buffer until its pool drains
    // (mode "leak"), and without it memory grows 16.6 MB per 1080p frame.
    // Warm up kernels and the context once.
    let warm = ParticleFilter(context: ctx)!
    for f in frames.prefix(4) { if let o = warm.push(CIImage(cvPixelBuffer: f.0), at: f.1) { _ = r.render(o.image, like: f.0) } }
    _ = warm.finish()
    func time(_ name: String, _ body: () async -> Int) async {
        let t0 = Date()
        let n = await body()
        let t = Date().timeIntervalSince(t0)
        precondition(n == frames.count, "\(name): frame count changed \(n)")
        print(String(format: "   %-28@ %6.1f fps (%d frames)", name as NSString, Double(n) / t, n))
    }
    print("== speed \(clip) at \(start) s, \(w)x\(h)\(size == nil ? "" : " (reader-scaled)"), \(frames.count) preloaded frames")
    let t0 = Date(); let compiled = ParticleFilter(context: ctx); print(String(format: "   ParticleFilter init (kernel compile) %.1f ms", Date().timeIntervalSince(t0) * 1000), compiled != nil)
    await time("render only (CI -> 420v)") { frames.reduce(0) { n, f in _ = r.render(CIImage(cvPixelBuffer: f.0), like: f.0); return n + 1 } }
    await time("b denoise 0.5") {
        let d = TemporalDenoiser(width: w, height: h, hdr: false, strength: 0.5)!
        var n = 0
        for f in frames { if await d.push(f.0, at: f.1) != nil { n += 1 } }
        return n + (await d.finish()).count
    }
    await time("c particle + render") {
        let p = ParticleFilter(context: ctx)!
        var n = 0
        for f in frames { autoreleasepool { if let o = p.push(CIImage(cvPixelBuffer: f.0), at: f.1) { _ = r.render(o.image, like: lookup[o.time]!); n += 1 } } }
        for o in p.finish() { autoreleasepool { _ = r.render(o.image, like: lookup[o.time]!); n += 1 } }
        return n
    }
    await time("d denoise>particle + render") {
        let d = TemporalDenoiser(width: w, height: h, hdr: false, strength: 0.5)!, p = ParticleFilter(context: ctx)!
        var n = 0
        func use(_ o: TemporalDenoiser.Frame) { autoreleasepool { if let q = p.push(CIImage(cvPixelBuffer: o.buffer), at: o.time) { _ = r.render(q.image, like: lookup[q.time]!); n += 1 } } }
        for f in frames { if let o = await d.push(f.0, at: f.1) { use(o) } }
        for o in await d.finish() { use(o) }
        for q in p.finish() { autoreleasepool { _ = r.render(q.image, like: lookup[q.time]!); n += 1 } }
        return n
    }
    await time("e particle>denoise (+render)") {
        let d = TemporalDenoiser(width: w, height: h, hdr: false, strength: 0.5)!, p = ParticleFilter(context: ctx)!
        var n = 0
        func rendered(_ q: ParticleFilter.Frame) -> CVPixelBuffer { autoreleasepool { r.compressed(r.render(q.image, like: lookup[q.time]!)) } }
        for f in frames { if let q = autoreleasepool(invoking: { p.push(CIImage(cvPixelBuffer: f.0), at: f.1) }) {
            if await d.push(rendered(q), at: q.time) != nil { n += 1 } } }
        for q in p.finish() { if await d.push(rendered(q), at: q.time) != nil { n += 1 } }
        return n + (await d.finish()).count
    }
    // Cost split for one particle filter: push (peak render + probe render + CPU motion) and the final render.
    let p = ParticleFilter(context: ctx)!
    var pushT = 0.0, renderT = 0.0, motionT = 0.0
    var outs: [ParticleFilter.Frame] = []
    for f in frames { autoreleasepool {
        let t0 = Date(); if let o = p.push(CIImage(cvPixelBuffer: f.0), at: f.1) { outs.append(o) }; pushT += Date().timeIntervalSince(t0)
        if let o = outs.popLast() { let t1 = Date(); _ = r.render(o.image, like: lookup[o.time]!); renderT += Date().timeIntervalSince(t1) }
    } }
    for o in p.finish() { let t1 = Date(); _ = r.render(o.image, like: lookup[o.time]!); renderT += Date().timeIntervalSince(t1) }
    // GPU motion alone: probe render of both frames + block search + read back, one command buffer each time.
    let est = ParticleFilter.MotionEstimator()!
    let lumaOf = { (b: CVPixelBuffer) in CIImage(cvPixelBuffer: b).applyingFilter("CIColorMatrix", parameters: [:]) }
    let t2 = Date()
    for i in 0..<20 {
        let cb = est.queue.makeCommandBuffer()!
        let pa = est.probe(lumaOf(frames[i].0), width: w, height: h, context: ctx, into: cb)!
        let pb = est.probe(lumaOf(frames[i + 1].0), width: w, height: h, context: ctx, into: cb)!
        let v = est.encodeField(from: pa, to: pb, into: cb)!; cb.commit(); await cb.completed()
        _ = est.field(v, width: w, height: h)
    }
    motionT = Date().timeIntervalSince(t2) / 20
    let n = Double(frames.count)
    print(String(format: "   split: push %.2f ms/frame, final render %.2f ms/frame; GPU motion alone (2 probes + search) %.2f ms", pushT / n * 1000, renderT / n * 1000, motionT * 1000))
}

/// Fish check at the middle frame. "fishauto": the 240x135 window with the most persistent dark groups.
/// "fishhand": the hand-picked window from the command line, centred on the same size, when given.
/// Layout, 2x zoom, contrast x3 around the crop mean: original | particle | particle>denoise,
/// then |difference| x4 against the original for particle and particle>denoise.
func saveFishCrops(_ tag: String, _ imgs: [RGBA], _ fish: [Blob], _ w: Int, _ h: Int, handPicked: (Int, Int)?) {
    let cw = 240, ch = 135
    var top = (-1, 0, 0)
    for y in stride(from: 0, through: h - ch, by: 16) { for x in stride(from: 0, through: w - cw, by: 16) {
        let n = fish.filter { Int($0.cx) >= x && Int($0.cx) < x + cw && Int($0.cy) >= y && Int($0.cy) < y + ch }.count
        if n > top.0 { top = (n, x, y) } } }
    var windows = [("fishauto", top.1, top.2, top.0)]
    if let (hx, hy) = handPicked {
        let x = min(w - cw, max(0, hx + 80 - cw / 2)), y = min(h - ch, max(0, hy + 45 - ch / 2))
        windows.append(("fishhand", x, y, fish.filter { Int($0.cx) >= x && Int($0.cx) < x + cw && Int($0.cy) >= y && Int($0.cy) < y + ch }.count))
    }
    // FISH_AT="x,y": a window placed by eye from the thumbnails in look/ (top-left, full-resolution pixels).
    if let at = ProcessInfo.processInfo.environment["FISH_AT"]?.split(separator: ",").compactMap({ Int($0) }), at.count == 2 {
        windows.append(("fishthumb", at[0], at[1], fish.filter { Int($0.cx) >= at[0] && Int($0.cx) < at[0] + cw && Int($0.cy) >= at[1] && Int($0.cy) < at[1] + ch }.count))
    }
    try? FileManager.default.createDirectory(atPath: "\(root)/crops2", withIntermediateDirectories: true)
    for (name, x, y, n) in windows {
        let c = [0, 2, 4].map { crop(imgs[$0], x: x, y: y, w: cw, h: ch, scale: 2, stretch: 3) }
        let plain = [0, 2, 4].map { crop(imgs[$0], x: x, y: y, w: cw, h: ch, scale: 2) }
        let d = [1, 2].map { diffImage(plain[0], plain[$0], gain: 4) }
        savePNG(grid([c, d]), "\(root)/crops2/\(tag)_\(name).png")
        print("   crop \(name): x \(x) y \(y) (240x135 at 2x, contrast x3), persistent dark groups inside \(n) of \(fish.count)")
    }
}
