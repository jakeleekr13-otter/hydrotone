import CoreImage
import CoreMedia
import CoreVideo
import Metal

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
/// use every frame it returns, then call `finish` once. It holds 1 previous and 2 next frames, plus the newest
/// frame while its GPU work runs, so output lags input by 3 frames. Frame count, order and times never change.
/// Not thread-safe: one instance per export, called from one task.
final class ParticleFilter {
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

    /// Camera motion on the GPU (Metal compute), block matching on 1/4-scale luma and its 1/8-scale half.
    /// Content at p in frame a sits at p + v in frame b, in full-resolution pixels, y down.
    /// Global shift: ±80 px search on 1/8 scale with each side's mean removed (frame width up to 8384 px), then ±2 px and a parabola fit
    /// on 1/4 scale. Per 64 px block: ±40 px around the global shift on 1/8 scale, then ±1 px and a parabola fit
    /// on 1/4 scale. A block keeps the global shift unless its best match is clearly better (flat water has
    /// no signal). A 3x3 median on the CPU then removes single-block outliers.
    final class MotionEstimator {
        struct Probe { let quarter: any MTLTexture, coarse: any MTLTexture }
        let device: any MTLDevice
        let queue: any MTLCommandQueue
        private let halve, coarseBand, coarseFinal, globalFine, shift, blocks: any MTLComputePipelineState
        private let coarseCost, fineCost, global, partial, aPartial: any MTLBuffer
        /// One result buffer per command buffer in flight, used in turn.
        private var results: [any MTLBuffer] = []
        private var result = 0
        /// Two probe slots, used in turn: the frame being measured and the one before it.
        private var slots: [Probe] = []
        private var slot = 0

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
            let options = MTLCompileOptions()
            options.mathMode = .safe
            guard let library = try? device.makeLibrary(source: Self.source, options: options),
                  let pipes = try? ["halve", "coarseBand", "coarseCost", "globalFine", "shift", "blocks"].map({ name -> any MTLComputePipelineState in
                      guard let f = library.makeFunction(name: name) else { throw CocoaError(.featureUnsupported) }
                      return try device.makeComputePipelineState(function: f) }),
                  let cc = device.makeBuffer(length: 441 * 4), let fc = device.makeBuffer(length: 25 * 4),
                  let gs = device.makeBuffer(length: 8), let pp = device.makeBuffer(length: 2 * 441 * 8 * 4),
                  let ap = device.makeBuffer(length: 8 * 4) else { return nil }
            self.device = device; self.queue = queue
            halve = pipes[0]; coarseBand = pipes[1]; coarseFinal = pipes[2]; globalFine = pipes[3]; shift = pipes[4]; blocks = pipes[5]
            coarseCost = cc; fineCost = fc; global = gs; partial = pp; aPartial = ap
        }

        /// Encodes the 1/4-scale render of `luma` (origin 0, full size w x h) and its 1/8-scale half into the next slot.
        /// The probe stays valid until the call after next.
        func probe(_ luma: CIImage, width w: Int, height h: Int, context: CIContext, into cb: any MTLCommandBuffer) -> Probe? {
            let qw = w / 4, qh = h / 4
            func texture(_ tw: Int, _ th: Int) -> (any MTLTexture)? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: tw, height: th, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            if slots.first?.quarter.width != qw || slots.first?.quarter.height != qh {
                slots = (0..<2).compactMap { _ in texture(qw, qh).flatMap { q in texture(qw / 2, qh / 2).map { Probe(quarter: q, coarse: $0) } } }
            }
            guard slots.count == 2 else { return nil }
            let (quarter, coarse) = (slots[slot].quarter, slots[slot].coarse)
            slot = 1 - slot
            let small = luma.transformed(by: CGAffineTransform(scaleX: CGFloat(qw) / CGFloat(w), y: CGFloat(qh) / CGFloat(h)),
                                         highQualityDownsample: true)
            let destination = CIRenderDestination(mtlTexture: quarter, commandBuffer: cb)
            destination.colorSpace = nil
            // Row 0 is the top of the image, as in a CVPixelBuffer and in the CPU version this replaced.
            destination.isFlipped = true
            guard (try? context.startTask(toRender: small, from: CGRect(x: 0, y: 0, width: qw, height: qh), to: destination, at: .zero)) != nil,
                  let e = cb.makeComputeCommandEncoder() else { return nil }
            e.setComputePipelineState(halve); e.setTexture(quarter, index: 0); e.setTexture(coarse, index: 1)
            e.dispatchThreads(MTLSize(width: qw / 2, height: qh / 2, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            e.endEncoding()
            return Probe(quarter: quarter, coarse: coarse)
        }

        /// Encodes the block search from `a` to `b`. Returns the buffer to read with `field` after `cb` completes.
        /// It stays valid until 3 more searches are encoded.
        func encodeField(from a: Probe, to b: Probe, into cb: any MTLCommandBuffer) -> (any MTLBuffer)? {
            let count = (a.quarter.width / 16) * (a.quarter.height / 16)
            if (results.first?.length ?? 0) < count * 8 {
                results = (0..<4).compactMap { _ in device.makeBuffer(length: count * 8, options: .storageModeShared) }
            }
            guard results.count == 4, a.coarse.width - 24 <= 1024, let e = cb.makeComputeCommandEncoder() else { return nil }
            let vectors = results[result]
            result = (result + 1) % 4
            let group = MTLSize(width: 256, height: 1, depth: 1)
            e.setTextures([a.coarse, b.coarse], range: 0..<2)
            e.setBuffer(coarseCost, offset: 0, index: 0); e.setBuffer(partial, offset: 0, index: 4); e.setBuffer(aPartial, offset: 0, index: 5)
            e.setComputePipelineState(coarseBand)
            for pass in [Int32(0), 1] {
                var p = pass
                e.setBytes(&p, length: 4, index: 6)
                e.dispatchThreadgroups(MTLSize(width: 21, height: 8, depth: 1), threadsPerThreadgroup: group)
            }
            e.setComputePipelineState(coarseFinal)
            e.dispatchThreads(MTLSize(width: 441, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            e.setComputePipelineState(globalFine); e.setTextures([a.quarter, b.quarter], range: 0..<2); e.setBuffer(fineCost, offset: 0, index: 1)
            e.dispatchThreadgroups(MTLSize(width: 25, height: 1, depth: 1), threadsPerThreadgroup: group)
            e.setComputePipelineState(shift); e.setBuffer(global, offset: 0, index: 3)
            e.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            e.setComputePipelineState(blocks); e.setTextures([a.quarter, b.quarter, a.coarse, b.coarse], range: 0..<4)
            e.setBuffer(vectors, offset: 0, index: 2)
            e.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            e.endEncoding()
            return vectors
        }

        /// A search result for frames of full size w x h, after its command buffer completed, with the 3x3 median applied.
        func field(_ vectors: any MTLBuffer, width w: Int, height h: Int) -> MotionField {
            let gw = w / 64, gh = h / 64
            let raw = Array(UnsafeBufferPointer(start: vectors.contents().assumingMemoryBound(to: SIMD2<Float>.self), count: gw * gh))
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

        static let source = """
        #include <metal_stdlib>
        using namespace metal;

        // 1/8 scale: mean of each 2x2 block of the 1/4-scale luma.
        kernel void halve(texture2d<float, access::read> q [[texture(0)]], texture2d<float, access::write> c [[texture(1)]],
                          uint2 p [[thread_position_in_grid]]) {
            if (p.x >= c.get_width() || p.y >= c.get_height()) { return; }
            const uint2 s = 2 * p;
            c.write(float4((q.read(s).r + q.read(s + uint2(1, 0)).r + q.read(s + uint2(0, 1)).r + q.read(s + uint2(1, 1)).r) / 4.0f), p);
        }

        // Sum over one threadgroup of 256 threads.
        static float groupSum(float v, threadgroup float *s, uint t) {
            v = simd_sum(v);
            if (t % 32 == 0) { s[t / 32] = v; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            float total = 0.0f;
            for (uint i = 0; i < 8; i++) { total += s[i]; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            return total;
        }

        // Mean absolute difference of a(p) and b(p + d) over the inner area, with each side's mean removed.
        // Threads split each row; the rows run in order.
        static float centred(texture2d<float, access::read> a, texture2d<float, access::read> b, int2 d, int margin,
                             threadgroup float *s, uint t) {
            const int x1 = int(a.get_width()) - margin, y1 = int(a.get_height()) - margin;
            const float n = float((x1 - margin) * (y1 - margin));
            float ma = 0.0f, mb = 0.0f;
            for (int y = margin; y < y1; y++) {
                for (int x = margin + int(t); x < x1; x += 256) { ma += a.read(uint2(x, y)).r; mb += b.read(uint2(x + d.x, y + d.y)).r; }
            }
            const float off = (groupSum(mb, s, t) - groupSum(ma, s, t)) / n;
            float sum = 0.0f;
            for (int y = margin; y < y1; y++) {
                for (int x = margin + int(t); x < x1; x += 256) { sum += abs(a.read(uint2(x, y)).r + off - b.read(uint2(x + d.x, y + d.y)).r); }
            }
            return groupSum(sum, s, t) / n;
        }

        static int argmin(device const float *c, int n) {
            int k = 0;
            for (int i = 1; i < n; i++) { if (c[i] < c[k]) { k = i; } }
            return k;
        }

        // Coarse global search, -10...10 px on 1/8 scale, 441 offsets in order dy, then dx.
        // One threadgroup per (dy, band of rows). Each row of a and of b is loaded once into threadgroup memory
        // and serves all 21 dx offsets: thread t < 252 owns offset dx = t % 21 - 10 and one of 12 row chunks.
        // pass 0: partial sums of b(p + d), and of a(p) (same for every d). pass 1: partial sums of
        // |a(p) + off - b(p + d)|, where off = mean b(p + d) - mean a(p) from the pass 0 sums.
        // part layout: [pass][offset][band]. aPart: [band]. Inner width is at most 1024 (checked on the CPU).
        constant int R = 10, M = 12, BANDS = 8, CHUNKS = 12;
        kernel void coarseBand(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                               device float *part [[buffer(4)]], device float *aPart [[buffer(5)]], constant int &pass [[buffer(6)]],
                               uint2 g [[threadgroup_position_in_grid]], uint t [[thread_index_in_threadgroup]]) {
            threadgroup float ta[1024], tb[1024 + 2 * R], red[256], redA[CHUNKS];
            const int iw = int(a.get_width()) - 2 * M, rows = int(a.get_height()) - 2 * M;
            const int dy = int(g.x) - R, band = int(g.y), r0 = M + rows * band / BANDS, r1 = M + rows * (band + 1) / BANDS;
            const int dxi = int(t) % 21, chunk = int(t) / 21, cw = (iw + CHUNKS - 1) / CHUNKS;
            const int c0 = min(iw, chunk * cw), c1 = min(iw, c0 + cw), offset = (dy + R) * 21 + dxi;
            float off = 0.0f;
            if (pass == 1 && t < 252) {
                float sa = 0.0f, sb = 0.0f;
                for (int k = 0; k < BANDS; k++) { sa += aPart[k]; sb += part[offset * BANDS + k]; }
                off = (sb - sa) / float(iw * rows);
            }
            float acc = 0.0f, accA = 0.0f;
            for (int y = r0; y < r1; y++) {
                for (int i = int(t); i < iw; i += 256) { ta[i] = a.read(uint2(M + i, y)).r; }
                for (int i = int(t); i < iw + 2 * R; i += 256) { tb[i] = b.read(uint2(M - R + i, y + dy)).r; }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (t < 252) {
                    if (pass == 0) {
                        for (int i = c0; i < c1; i++) { acc += tb[i + dxi]; }
                        if (dxi == 0) { for (int i = c0; i < c1; i++) { accA += ta[i]; } }
                    } else {
                        for (int i = c0; i < c1; i++) { acc += abs(ta[i] + off - tb[i + dxi]); }
                    }
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
            red[t] = acc;
            if (dxi == 0 && t < 252) { redA[chunk] = accA; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (t < 21) {
                float sum = 0.0f;
                for (int c = 0; c < CHUNKS; c++) { sum += red[c * 21 + int(t)]; }
                part[(pass * 441 + (dy + R) * 21 + int(t)) * BANDS + band] = sum;
            }
            if (pass == 0 && t == 0 && g.x == 0) {
                float sum = 0.0f;
                for (int c = 0; c < CHUNKS; c++) { sum += redA[c]; }
                aPart[band] = sum;
            }
        }

        // Coarse cost per offset from the pass 1 partial sums. One thread per offset.
        kernel void coarseCost(texture2d<float, access::read> a [[texture(0)]], device const float *part [[buffer(4)]],
                               device float *cost [[buffer(0)]], uint g [[thread_position_in_grid]]) {
            if (g >= 441) { return; }
            float sum = 0.0f;
            for (int k = 0; k < BANDS; k++) { sum += part[(441 + int(g)) * BANDS + k]; }
            cost[g] = sum / float((int(a.get_width()) - 2 * M) * (int(a.get_height()) - 2 * M));
        }

        // One threadgroup per offset, ±2 px on 1/4 scale around the best coarse offset.
        kernel void globalFine(texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::read> b [[texture(1)]],
                               device const float *coarse [[buffer(0)]], device float *cost [[buffer(1)]],
                               uint g [[threadgroup_position_in_grid]], uint t [[thread_index_in_threadgroup]]) {
            threadgroup float s[8];
            const int k = argmin(coarse, 441);
            const int2 d = 2 * int2(k % 21 - 10, k / 21 - 10) + int2(int(g % 5) - 2, int(g / 5) - 2);
            const float v = centred(a, b, d, 24, s, t);
            if (t == 0) { cost[g] = v; }
        }

        static float parabola(float l, float m, float r) {
            const float d = l - 2.0f * m + r;
            return d > 0.0f && isfinite(d) ? max(-0.5f, min(0.5f, (l - r) / (2.0f * d))) : 0.0f;
        }

        // Mean absolute difference of a size x size block at (x0, y0) and the block moved by d. FLT_MAX off the edge.
        static float blockCost(texture2d<float, access::read> a, texture2d<float, access::read> b, int x0, int y0, int size, int2 d) {
            if (x0 + d.x < 0 || y0 + d.y < 0 || x0 + size + d.x > int(a.get_width()) || y0 + size + d.y > int(a.get_height())) { return FLT_MAX; }
            float sum = 0.0f;
            for (int y = y0; y < y0 + size; y++) {
                for (int x = x0; x < x0 + size; x++) { sum += abs(a.read(uint2(x, y)).r - b.read(uint2(x + d.x, y + d.y)).r); }
            }
            return sum / float(size * size);
        }

        // The global shift from both searches, in full-resolution pixels. One thread.
        kernel void shift(device const float *coarse [[buffer(0)]], device const float *fine [[buffer(1)]],
                          device float2 *global [[buffer(3)]]) {
            const int k = argmin(coarse, 441), f = argmin(fine, 25), i = f % 5, j = f / 5;
            const float sx = (i > 0 && i < 4) ? parabola(fine[f - 1], fine[f], fine[f + 1]) : 0.0f;
            const float sy = (j > 0 && j < 4) ? parabola(fine[f - 5], fine[f], fine[f + 5]) : 0.0f;
            global[0] = float2(float(2 * (k % 21 - 10) + i - 2) + sx, float(2 * (k / 21 - 10) + j - 2) + sy) * 4.0f;
        }

        // One threadgroup (128 threads) per 64 px block, 16 px on 1/4 scale. out: vectors in full-resolution pixels.
        // Offsets are scanned in the order dy, then dx, and the first lowest cost wins.
        kernel void blocks(texture2d<float, access::read> a4 [[texture(0)]], texture2d<float, access::read> b4 [[texture(1)]],
                           texture2d<float, access::read> a8 [[texture(2)]], texture2d<float, access::read> b8 [[texture(3)]],
                           device float2 *out [[buffer(2)]], device const float2 *globalShift [[buffer(3)]],
                           uint g [[threadgroup_position_in_grid]], uint t [[thread_index_in_threadgroup]]) {
            threadgroup float coarse[121], fine[10];
            const int gw = int(a4.get_width()) / 16, bx = int(g) % gw, by = int(g) / gw;
            const float2 global = globalShift[0];
            const int2 g8 = int2(round(global / 8.0f));
            if (t < 121) { coarse[t] = blockCost(a8, b8, bx * 8, by * 8, 8, g8 + int2(int(t % 11) - 5, int(t / 11) - 5)); }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            int k = 0;
            for (int n = 1; n < 121; n++) { if (coarse[n] < coarse[k]) { k = n; } }
            const int2 at = g8 + int2(k % 11 - 5, k / 11 - 5);
            if (t < 10) {
                const int2 d = t < 9 ? 2 * at + int2(int(t % 3) - 1, int(t / 3) - 1) : int2(round(global / 4.0f));
                fine[t] = blockCost(a4, b4, bx * 16, by * 16, 16, d);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (t != 0) { return; }
            int m = 0;
            for (int n = 1; n < 9; n++) { if (fine[n] < fine[m]) { m = n; } }
            const float atGlobal = fine[9];
            if (!(fine[m] < 0.8f * atGlobal && atGlobal - fine[m] > 0.002f)) { out[g] = global; return; }
            const float vx = m % 3 == 1 ? parabola(fine[3], fine[4], fine[5]) : 0.0f;
            const float vy = m / 3 == 1 ? parabola(fine[1], fine[4], fine[7]) : 0.0f;
            out[g] = float2(float(2 * at.x + m % 3 - 1) + vx, float(2 * at.y + m / 3 - 1) + vy) * 4.0f;
        }
        """
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
    private let tileKernel: CIKernel
    private let motion: MotionEstimator
    private var pool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    /// The last frame's probe, the start of the next motion search.
    private var probe: MotionEstimator.Probe?
    private var window: [Entry] = []
    private var cursor = 0
    private let previousCount = 1, nextCount = 2

    private struct Entry {
        let image: CIImage
        /// r: spot contrast, g: contrast needed, b: blurred luma. Valid once `work` is nil and `usable` is true.
        let peak: CIImage
        let time: CMTime
        var motionToNext: MotionField?
        /// GPU work still running: the peak render, the probe and the search from the previous frame.
        var work: Work?
        var usable: Bool
    }

    private struct Work {
        let commands: any MTLCommandBuffer
        /// Keeps the Metal view of the peak buffer alive until the GPU wrote it.
        let target: CVMetalTexture
        let vectors: (any MTLBuffer)?
    }

    /// Returns nil when the Metal kernels fail to compile. The caller then uses frames unchanged.
    init?(context: CIContext, settings: Settings = Settings()) {
        guard let kernels = try? CIKernel.kernels(withMetalString: Self.metalSource),
              let luma = kernels.first(where: { $0.name == "HydroToneSpeckLuma" }) as? CIColorKernel,
              let peak = kernels.first(where: { $0.name == "HydroToneSpeckPeak" }),
              let mask = kernels.first(where: { $0.name == "HydroToneSpeckMask" }),
              let fill = kernels.first(where: { $0.name == "HydroToneSpeckFill" }),
              let tiles = kernels.first(where: { $0.name == "HydroToneSpeckTiles" }),
              let motion = MotionEstimator() else { return nil }
        self.context = context
        self.settings = settings
        lumaKernel = luma; peakKernel = peak; maskKernel = mask; fillKernel = fill; tileKernel = tiles
        self.motion = motion
    }

    /// Adds one frame. Returns the frame that is now ready, or nil while the look-ahead fills.
    /// A frame smaller than 64x64 or of another size than the first passes through unchanged.
    func push(_ image: CIImage, at time: CMTime) -> Frame? {
        if let first = window.first, first.image.extent.size != image.extent.size { return Frame(image: image, time: time) }
        guard let entry = prepare(image, at: time) else { return Frame(image: image, time: time) }
        window.append(entry)
        guard window.count - cursor > nextCount + 1 else { return nil }
        return emit()
    }

    /// Flushes the look-ahead. Call once after the last `push`.
    func finish() -> [Frame] {
        var frames: [Frame] = []
        while cursor < window.count { frames.append(emit()) }
        window.removeAll(); cursor = 0; probe = nil
        return frames
    }

    /// Waits for the GPU work of every entry up to `last` and takes its motion field.
    private func settle(through last: Int) {
        for i in window.indices where i <= last {
            guard let work = window[i].work else { continue }
            work.commands.waitUntilCompleted()
            window[i].work = nil
            window[i].usable = work.commands.status == .completed
            if window[i].usable, i > 0, let v = work.vectors {
                let e = window[i].image.extent
                window[i - 1].motionToNext = motion.field(v, width: Int(e.width), height: Int(e.height))
            }
        }
        if let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
    }

    private func emit() -> Frame {
        settle(through: min(window.count - 1, cursor + nextCount))
        let source = window[cursor]
        var neighbours: [(CIImage, MotionField)] = []
        if cursor > 0, window[cursor - 1].usable, let m = window[cursor - 1].motionToNext { neighbours.append((window[cursor - 1].peak, -m)) }
        var chained: MotionField?
        for i in (cursor + 1)..<min(window.count, cursor + 1 + nextCount) {
            guard window[i].usable, let step = window[i - 1].motionToNext else { break }
            chained = chained.map { $0 + step } ?? step
            neighbours.append((window[i].peak, chained!))
        }
        let output = source.usable ? filtered(source, neighbours: neighbours) : source.image
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
        var peaks = neighbours.map(\.0)
        var fields = neighbours.map(\.1)
        while peaks.count < 3 { peaks.append(empty); fields.append(fields[0]) }
        let flowA = flowImage(fields[0], fields[1], extent: extent), flowB = flowImage(fields[2], fields[2], extent: extent)
        let reach = CGFloat(2 * s.contextRadius + 6)
        let cur = source.peak
        // The blocks cover whole 64 px cells from the top. Core Image rows start at the bottom.
        let flowExtent = flowA.extent, covered = flowExtent.height * CGFloat(MotionField.block)
        let tileExtent = CGRect(x: 0, y: 0, width: (extent.width / 8).rounded(.up), height: (extent.height / 8).rounded(.up))
        guard let tiles = tileKernel.apply(extent: tileExtent, roiCallback: { _, r in
                  CGRect(x: extent.minX + 8 * r.minX, y: extent.minY + 8 * r.minY, width: 8 * r.width, height: 8 * r.height) },
                  arguments: [cur, CIVector(x: extent.minX, y: extent.minY)]),
              let mask = maskKernel.apply(extent: extent, roiCallback: { i, r in
                  switch i {
                  case 0: r.insetBy(dx: -reach, dy: -reach).intersection(extent)
                  case 1...3: r.insetBy(dx: -reach - 256, dy: -reach - 256).intersection(extent)
                  case 4, 5: flowExtent
                  default: tileExtent
                  } },
                  arguments: [cur, peaks[0], peaks[1], peaks[2], flowA, flowB, tiles,
                              CIVector(x: CGFloat(neighbours.count), y: CGFloat(s.matchRatio),
                                       z: CGFloat(s.contextRadius), w: CGFloat(s.contextTolerance)),
                              CIVector(x: CGFloat(s.floor), y: 0, z: 0, w: 0),
                              CIVector(x: extent.minX, y: extent.minY, z: extent.maxX, w: extent.maxY),
                              CIVector(x: extent.minX, y: extent.maxY - covered, z: flowExtent.width, w: flowExtent.height)]),
              let out = fillKernel.apply(extent: extent, roiCallback: { _, r in
                  r.insetBy(dx: CGFloat(-s.fillRadius - 2), dy: CGFloat(-s.fillRadius - 2)) },
                  arguments: [source.image.clampedToExtent(), mask.clampedToExtent(), CIVector(x: CGFloat(s.fillRadius), y: 0, z: 0, w: 0)])
        else { return source.image }
        return out.cropped(to: extent)
    }

    /// Two motion fields as one small image, one texel per block, in Core Image axes (y up).
    /// The mask kernel samples it bilinearly between block centres.
    private func flowImage(_ a: MotionField, _ b: MotionField, extent: CGRect) -> CIImage {
        var values = [Float](repeating: 0, count: a.gw * a.gh * 4)
        for row in 0..<a.gh { for x in 0..<a.gw {
            let src = row * a.gw + x, dst = ((a.gh - 1 - row) * a.gw + x) * 4
            values[dst] = a.vectors[src].x; values[dst + 1] = -a.vectors[src].y
            values[dst + 2] = b.vectors[src].x; values[dst + 3] = -b.vectors[src].y
        }}
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: a.gw * 16, size: CGSize(width: a.gw, height: a.gh),
                       format: .RGBAf, colorSpace: nil).samplingLinear()
    }

    /// Encodes and commits the GPU work for one frame: the peak map, the 1/4-scale luma probe and the motion
    /// from the previous frame to this one. Nothing waits here; `settle` collects the result later.
    /// Returns nil only for a frame too small to filter. When the GPU work cannot be set up, the entry is
    /// marked unusable and the frame later passes through unchanged, in order.
    private func prepare(_ image: CIImage, at time: CMTime) -> Entry? {
        let extent = image.extent
        let w = Int(extent.width), h = Int(extent.height)
        guard w >= 64, h >= 64 else { return nil }
        let s = settings
        let toOrigin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        if textureCache == nil { CVMetalTextureCacheCreate(nil, nil, motion.device, nil, &textureCache) }
        var wrapped: CVMetalTexture?
        guard let luma = lumaKernel.apply(extent: extent, arguments: [image]),
              let peakRecipe = peakKernel.apply(extent: extent, roiCallback: { _, r in
                  r.insetBy(dx: CGFloat(-s.ringRadius - 2), dy: CGFloat(-s.ringRadius - 2)) },
                  arguments: [luma.clampedToExtent().applyingGaussianBlur(sigma: 0.8),
                              CIVector(x: CGFloat(s.ringRadius), y: CGFloat(s.floor), z: CGFloat(s.spreadGain), w: CGFloat(s.maxContrast))]),
              let buffer = peakBuffer(width: w, height: h), let textureCache,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .rgba16Float, w, h, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let texture = CVMetalTextureGetTexture(wrapped), let cb = motion.queue.makeCommandBuffer()
        else { return Entry(image: image, peak: image, time: time, usable: false) }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: cb)
        destination.colorSpace = nil
        destination.isFlipped = true
        let previous = window.last.flatMap { $0.usable ? probe : nil }
        guard (try? context.startTask(toRender: peakRecipe.transformed(by: toOrigin), from: CGRect(x: 0, y: 0, width: w, height: h),
                                      to: destination, at: .zero)) != nil,
              let current = motion.probe(luma.transformed(by: toOrigin), width: w, height: h, context: context, into: cb)
        else { probe = nil; return Entry(image: image, peak: image, time: time, usable: false) }
        let vectors = previous.flatMap { motion.encodeField(from: $0, to: current, into: cb) }
        cb.commit()
        probe = current
        var peak = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        if extent.origin != .zero { peak = peak.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)) }
        return Entry(image: image, peak: peak, time: time, work: Work(commands: cb, target: wrapped, vectors: vectors), usable: true)
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
    // Sample with p clamped to the pixel centres of extent e = (min x, min y, max x, max y): the edge pixel
    // repeats outside, as with clampedToExtent, but Core Image needs no clamped copy of the input.
    static float4 clamped(coreimage::sampler s, float2 p, float4 e) { return s.sample(s.transform(clamp(p, e.xy + 0.5f, e.zw - 0.5f))); }

    static int look(coreimage::sampler cur, coreimage::sampler n, float2 at, float2 flow, float4 v, float4 q, float floorLevel, float4 e) {
        float diff = 0.0f;
        for (int i = 0; i < 32; i++) {
            const float2 r = (i < 16 ? q.z : 2.0f * q.z) * ring16[i % 16];
            diff += abs(clamped(cur, at + r, e).b - clamped(n, at + flow + r, e).b);
        }
        if (diff / 32.0f > q.w * v.r + 0.5f * floorLevel) { return 0; }
        const float need = max(v.r * q.y, 0.5f * v.g);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (clamped(n, at + flow + float2(dx, dy), e).r >= need) { return 1; }
            }
        }
        return 2;
    }

    // 1 when any pixel of this 8x8 tile is a spot candidate (contrast above the need), else 0.
    // Tile (i, j) covers origin + 8 * (i, j) and the 7 pixels after it on each axis.
    [[stitchable]] float4 HydroToneSpeckTiles(coreimage::sampler peak, float2 origin, coreimage::destination dest) {
        const float2 base = origin + 8.0f * floor(dest.coord());
        for (int y = 0; y < 8; y++) {
            for (int x = 0; x < 8; x++) {
                const float4 v = peak.sample(peak.transform(base + float2(x + 0.5f, y + 0.5f)));
                if (v.r > v.g) { return float4(1.0f); }
            }
        }
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }

    // r: how strongly this pixel belongs to a drifting spot, 0...1. A spot centre within 4 px marks it,
    // so the camera's dark sharpening halo around a speck is covered too.
    // q = (neighbour count, match ratio, context radius, context tolerance). q2.x = floor. e = extent (min x, min y, max x, max y).
    // The flow images hold one texel per 64 px block; fm = (origin of block (0, 0) in this image, block count x, y).
    // Pixels whose 9x9 window touches no candidate tile return 0 at once. Outside the extent the peak map is
    // clamped, so the window is clamped to the extent before the tiles are looked up.
    [[stitchable]] float4 HydroToneSpeckMask(coreimage::sampler cur, coreimage::sampler n0, coreimage::sampler n1,
                                             coreimage::sampler n2, coreimage::sampler flowA, coreimage::sampler flowB,
                                             coreimage::sampler tiles, float4 q, float4 q2, float4 e, float4 fm,
                                             coreimage::destination dest) {
        const float2 c = dest.coord();
        const float2 lo = clamp(c - 4.0f, e.xy + 0.5f, e.zw - 0.5f), hi = clamp(c + 4.0f, e.xy + 0.5f, e.zw - 0.5f);
        const int2 t0 = int2(floor((lo - e.xy) / 8.0f)), t1 = int2(floor((hi - e.xy) / 8.0f));
        bool candidate = false;
        for (int ty = t0.y; ty <= t1.y; ty++) {
            for (int tx = t0.x; tx <= t1.x; tx++) { candidate = candidate || tiles.sample(tiles.transform(float2(tx, ty) + 0.5f)).r > 0.5f; }
        }
        if (!candidate) { return float4(0.0f, 0.0f, 0.0f, 1.0f); }
        const int count = int(q.x);
        float best = 0.0f;
        for (int dy = -4; dy <= 4; dy++) {
            for (int dx = -4; dx <= 4; dx++) {
                const float2 o = c + float2(dx, dy);
                const float4 v = clamped(cur, o, e);
                if (v.r <= v.g) { continue; }
                const float2 f = clamp((o - fm.xy) / 64.0f, float2(0.5f), fm.zw - 0.5f);
                const float4 fa = flowA.sample(flowA.transform(f));
                const float2 fb = flowB.sample(flowB.transform(f)).rg;
                bool gone = look(cur, n0, o, fa.rg, v, q, q2.x, e) == 2;
                if (!gone && count > 1) { gone = look(cur, n1, o, fa.ba, v, q, q2.x, e) == 2; }
                if (!gone && count > 2) { gone = look(cur, n2, o, fb, v, q, q2.x, e) == 2; }
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
