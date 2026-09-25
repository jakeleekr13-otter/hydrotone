// Mode "mprof <clip> <start> [w h]": GPU time of the motion parts, separate command buffers, 20 repeats each.
import CoreImage
import CoreMedia
import Foundation
import Metal

func motionProfile(_ clip: String, _ start: Double, size: (Int, Int)?) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 1)
    var frames: [CVPixelBuffer] = []
    while frames.count < 22, let f = reader.next() { frames.append(f.0) }
    reader.reader.cancelReading()
    let ctx = CIContext()
    let est = ParticleFilter.MotionEstimator()!
    var images = frames.map { CIImage(cvPixelBuffer: $0) }
    if let size { images = images.map { $0.transformed(by: CGAffineTransform(scaleX: CGFloat(size.0) / $0.extent.width, y: CGFloat(size.1) / $0.extent.height)) } }
    let w = Int(images[0].extent.width), h = Int(images[0].extent.height)
    func gpu(_ body: (any MTLCommandBuffer) -> Void) async -> (Double, Double) {
        let cb = est.queue.makeCommandBuffer()!
        let t0 = Date(); body(cb); cb.commit(); await cb.completed()
        return ((cb.gpuEndTime - cb.gpuStartTime) * 1000, Date().timeIntervalSince(t0) * 1000)
    }
    var probes: [ParticleFilter.MotionEstimator.Probe] = []
    var pg = 0.0, pw = 0.0, fg = 0.0, fw = 0.0
    for i in 0..<22 { let (g, wall) = await gpu { probes.append(est.probe(images[i], width: w, height: h, context: ctx, into: $0)!) }; if i >= 2 { pg += g; pw += wall } }
    var last: (any MTLBuffer)?
    for i in 0..<21 {
        let cb = est.queue.makeCommandBuffer()!
        let pa = est.probe(images[i], width: w, height: h, context: ctx, into: cb)!, pb = est.probe(images[i + 1], width: w, height: h, context: ctx, into: cb)!
        cb.commit(); await cb.completed()
        let (g, wall) = await gpu { last = est.encodeField(from: pa, to: pb, into: $0) }; if i >= 1 { fg += g; fw += wall }
    }
    let t0 = Date(); for _ in 0..<20 { _ = est.field(last!, width: w, height: h) }; let med = Date().timeIntervalSince(t0) / 20 * 1000
    print(String(format: "== mprof %dx%d: probe render+halve GPU %.2f ms (wall %.2f), search GPU %.2f ms (wall %.2f), CPU median %.3f ms", w, h, pg / 20, pw / 20, fg / 20, fw / 20, med))
}

/// Mode "kprof <clip> <start> [w h]": GPU time of each motion kernel alone, 20 repeats.
func kernelProfile(_ clip: String, _ start: Double, size: (Int, Int)?) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 1)
    var frames: [CVPixelBuffer] = []
    while frames.count < 2, let f = reader.next() { frames.append(f.0) }
    reader.reader.cancelReading()
    let ctx = CIContext()
    let est = ParticleFilter.MotionEstimator()!
    var images = frames.map { CIImage(cvPixelBuffer: $0) }
    if let size { images = images.map { $0.transformed(by: CGAffineTransform(scaleX: CGFloat(size.0) / $0.extent.width, y: CGFloat(size.1) / $0.extent.height)) } }
    let w = Int(images[0].extent.width), h = Int(images[0].extent.height)
    let cb0 = est.queue.makeCommandBuffer()!
    let a = est.probe(images[0], width: w, height: h, context: ctx, into: cb0)!, b = est.probe(images[1], width: w, height: h, context: ctx, into: cb0)!
    cb0.commit(); await cb0.completed()
    let dev = est.device
    let o = MTLCompileOptions(); o.mathMode = .safe
    let lib = try await dev.makeLibrary(source: ParticleFilter.MotionEstimator.source, options: o)
    func pipe(_ n: String) throws -> any MTLComputePipelineState { try dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
    let pc = try pipe("coarseBand"), pcf = try pipe("coarseCost"), pf = try pipe("globalFine"), ps = try pipe("shift"), pb = try pipe("blocks")
    let cc = dev.makeBuffer(length: 441 * 4)!, fc = dev.makeBuffer(length: 100)!, gs = dev.makeBuffer(length: 8)!
    let pp = dev.makeBuffer(length: 2 * 441 * 8 * 4)!, ap = dev.makeBuffer(length: 8*4)!
    let count = (w / 64) * (h / 64), vec = dev.makeBuffer(length: count * 8)!
    func run(_ name: String, _ body: (any MTLComputeCommandEncoder) -> Void) async {
        var total = 0.0, low = 1.0
        for i in 0..<41 {
            let cb = est.queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.setTextures([a.quarter, b.quarter, a.coarse, b.coarse], range: 0..<4)
            e.setBuffer(cc, offset: 0, index: 0); e.setBuffer(fc, offset: 0, index: 1); e.setBuffer(vec, offset: 0, index: 2); e.setBuffer(gs, offset: 0, index: 3)
            e.setBuffer(pp, offset: 0, index: 4); e.setBuffer(ap, offset: 0, index: 5)
            body(e); e.endEncoding(); cb.commit(); await cb.completed()
            if i > 0 { total += cb.gpuEndTime - cb.gpuStartTime; low = min(low, cb.gpuEndTime - cb.gpuStartTime) }
        }
        print(String(format: "   %@ mean %.3f ms, min %.3f ms", name, total / 40 * 1000, low * 1000))
    }
    print("== kprof \(w)x\(h)")
    let g = MTLSize(width: 256, height: 1, depth: 1)
    await run("coarseBand x2 + coarseCost") {
        $0.setComputePipelineState(pc); $0.setTextures([a.coarse, b.coarse], range: 0..<2)
        for pass in [Int32(0), 1] { var p = pass; $0.setBytes(&p, length: 4, index: 6); $0.dispatchThreadgroups(MTLSize(width: 21, height: 8, depth: 1), threadsPerThreadgroup: g) }
        $0.setComputePipelineState(pcf); $0.dispatchThreads(MTLSize(width: 441, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)) }
    await run("globalFine") { $0.setComputePipelineState(pf); $0.dispatchThreadgroups(MTLSize(width: 25, height: 1, depth: 1), threadsPerThreadgroup: g) }
    await run("shift") { $0.setComputePipelineState(ps); $0.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)) }
    await run("blocks") { $0.setComputePipelineState(pb); $0.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1)) }
}

/// Mode "rprof <clip> <start> [v1]": final render of each output through CIRenderDestination, with CI's own
/// kernel time and pass count. 60 frames.
func renderProfile(_ clip: String, _ start: Double, v1: Bool) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 2)
    var frames: [(CVPixelBuffer, CMTime)] = []
    while frames.count < 64, let f = reader.next() { frames.append(f) }
    reader.reader.cancelReading()
    let ctx = CIContext()
    let r = Renderer(ctx)
    let w = CVPixelBufferGetWidth(frames[0].0), h = CVPixelBufferGetHeight(frames[0].0)
    let out = r.buffer(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let newF = ParticleFilter(context: ctx)!, oldF = ParticleFilterV1(context: ctx)!
    var kernel = 0.0, wall = 0.0, passes = 0, n = 0, pushT = 0.0
    for (i, f) in frames.enumerated() {
        let t0 = Date()
        let o = v1 ? oldF.push(CIImage(cvPixelBuffer: f.0), at: f.1).map { ($0.image, $0.time) } : newF.push(CIImage(cvPixelBuffer: f.0), at: f.1).map { ($0.image, $0.time) }
        if i >= 4 { pushT += Date().timeIntervalSince(t0) }
        guard let (img, _) = o else { continue }
        let d = CIRenderDestination(pixelBuffer: out)
        let t1 = Date()
        let info = try ctx.startTask(toRender: img, to: d).waitUntilCompleted()
        if i >= 4 { kernel += info.kernelExecutionTime; wall += Date().timeIntervalSince(t1); passes += info.passCount; n += 1 }
    }
    print(String(format: "== rprof %@ %dx%d: push wall %.2f ms, final render kernel %.2f ms, wall %.2f ms, passes %.1f (%d frames)", v1 ? "V1" : "new", w, h, pushT / Double(n) * 1000, kernel / Double(n) * 1000, wall / Double(n) * 1000, Double(passes) / Double(n), n))
}

/// Mode "oprof <clip> <start>": total particle + render time with 3 ways to render the output. 120 frames each.
func outputProfile(_ clip: String, _ start: Double) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 3)
    var frames: [(CVPixelBuffer, CMTime)] = []
    while frames.count < 120, let f = reader.next() { frames.append(f) }
    reader.reader.cancelReading()
    let ctx = CIContext()
    let r = Renderer(ctx)
    let w = CVPixelBufferGetWidth(frames[0].0), h = CVPixelBufferGetHeight(frames[0].0)
    let fixed = r.buffer(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let lookup = Dictionary(uniqueKeysWithValues: frames.map { ($0.1, $0.0) })
    let ways: [(String, (CIImage, CMTime) throws -> Void)] = [
        ("Renderer.render (new buffer, source colour space)", { img, t in _ = r.render(img, like: lookup[t]!) }),
        ("ctx.render to one reused buffer, source colour space", { img, t in ctx.render(img, to: fixed, bounds: img.extent, colorSpace: CIImage(cvPixelBuffer: lookup[t]!).colorSpace) }),
        ("startTask + wait, one reused buffer", { img, _ in _ = try ctx.startTask(toRender: img, to: CIRenderDestination(pixelBuffer: fixed)).waitUntilCompleted() }),
        ("Renderer.render, then wait for the GPU via startTask on a 1x1", { img, t in _ = r.render(img, like: lookup[t]!) }),
    ]
    for (name, way) in ways {
        for _ in 0..<2 {
            let p = ParticleFilter(context: ctx)!
            var n = 0
            let t0 = Date()
            for f in frames { if let o = p.push(CIImage(cvPixelBuffer: f.0), at: f.1) { try way(o.image, o.time); n += 1 } }
            for o in p.finish() { try way(o.image, o.time); n += 1 }
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "   %@: %.1f fps (%d frames)", name as NSString, Double(n) / dt, n))
        }
    }
}

/// Mode "drift <clip> <start> <passes> [gpu-only]": one filter, the 120 frames looped `passes` times, fps per 60 frames.
/// gpu-only: a plain Core Image blur + render instead of the filter, to see whether the GPU itself slows down.
func driftProfile(_ clip: String, _ start: Double, _ passes: Int, newContext: Bool) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 3)
    var frames: [(CVPixelBuffer, CMTime)] = []
    while frames.count < 120, let f = reader.next() { frames.append(f) }
    reader.reader.cancelReading()
    let ctx = CIContext()
    let r = Renderer(ctx)
    var line: [String] = []
    let p = ParticleFilter(context: ctx)!, v1 = ParticleFilterV1(context: ctx)!
    let useV1 = ProcessInfo.processInfo.environment["DRIFT_V1"] != nil
    var t0 = Date(), n = 0
    for pass in 0..<passes {
        for (i, f) in frames.enumerated() {
            let t = CMTime(value: CMTimeValue(pass * 120 + i), timescale: 60)
            autoreleasepool {
            if newContext {
                _ = r.render(CIImage(cvPixelBuffer: f.0).applyingGaussianBlur(sigma: 6).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), like: f.0); n += 1
            } else if useV1 { if let o = v1.push(CIImage(cvPixelBuffer: f.0), at: t) { _ = r.render(o.image, like: f.0); n += 1 } }
            else if let o = p.push(CIImage(cvPixelBuffer: f.0), at: t) { _ = r.render(o.image, like: f.0); n += 1 }
            }
            if n == 60 { line.append(String(format: "%.0f(%dMB)", 60 / Date().timeIntervalSince(t0), footprintMB())); t0 = Date(); n = 0 }
        }
    }
    print("   fps per 60 frames:", line.joined(separator: " "))
}

/// Mode "pprof <clip> <start>": GPU time of the peak-map recipe alone (luma, blur, peak), 40 renders, own command buffers.
func peakProfile(_ clip: String, _ start: Double) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: 1)
    var frames: [CVPixelBuffer] = []
    while frames.count < 41, let f = reader.next() { frames.append(f.0) }
    reader.reader.cancelReading()
    let ctx = CIContext()
    let est = ParticleFilter.MotionEstimator()!
    let w = CVPixelBufferGetWidth(frames[0]), h = CVPixelBufferGetHeight(frames[0])
    let src = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    constant float2 ring16[16] = {
        float2(1.0f, 0.0f), float2(0.9239f, 0.3827f), float2(0.7071f, 0.7071f), float2(0.3827f, 0.9239f),
        float2(0.0f, 1.0f), float2(-0.3827f, 0.9239f), float2(-0.7071f, 0.7071f), float2(-0.9239f, 0.3827f),
        float2(-1.0f, 0.0f), float2(-0.9239f, -0.3827f), float2(-0.7071f, -0.7071f), float2(-0.3827f, -0.9239f),
        float2(0.0f, -1.0f), float2(0.3827f, -0.9239f), float2(0.7071f, -0.7071f), float2(0.9239f, -0.3827f) };
    [[stitchable]] float4 L(coreimage::sample_t s) { const float l = sqrt(max(dot(s.rgb, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f)); return float4(l, l, l, 1.0f); }
    [[stitchable]] float4 P(coreimage::sampler lum, float4 p, coreimage::destination dest) {
        const float2 c = dest.coord(); const float centre = lum.sample(lum.transform(c)).r;
        float hi = -1.0e4f, lo = 1.0e4f, sum = 0.0f;
        for (int i = 0; i < 16; i++) { const float v = lum.sample(lum.transform(c + p.x * ring16[i])).r; hi = max(hi, v); lo = min(lo, v); sum += v; }
        const float need = centre - sum / 16.0f > p.w ? 1.0e4f : max(p.y, p.z * (hi - lo));
        return float4(centre - hi, need, centre, 1.0f); }
    """
    let ks = try CIKernel.kernels(withMetalString: src)
    let lk = ks.first { $0.name == "L" } as! CIColorKernel, pk = ks.first { $0.name == "P" }!
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite, .renderTarget]; desc.storageMode = .private
    let tex = est.device.makeTexture(descriptor: desc)!
    let e = CGRect(x: 0, y: 0, width: w, height: h)
    let recipes: [(String, (CIImage) -> CIImage)] = [
        ("luma only", { lk.apply(extent: e, arguments: [$0])! }),
        ("luma + blur 0.8", { lk.apply(extent: e, arguments: [$0])!.clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: e) }),
        ("luma + blur + peak (as filter)", { img in
            let b = lk.apply(extent: e, arguments: [img])!.clampedToExtent().applyingGaussianBlur(sigma: 0.8)
            return pk.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -7, dy: -7) }, arguments: [b, CIVector(x: 5, y: 4.0 / 219, z: 2, w: 30.0 / 219)])! }),
        ("luma + peak (no blur)", { img in
            let b = lk.apply(extent: e, arguments: [img])!.clampedToExtent()
            return pk.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -7, dy: -7) }, arguments: [b, CIVector(x: 5, y: 4.0 / 219, z: 2, w: 30.0 / 219)])! }),
    ]
    for (name, recipe) in recipes {
        var g = 0.0
        for i in 0..<41 {
            let cb = est.queue.makeCommandBuffer()!
            let d = CIRenderDestination(mtlTexture: tex, commandBuffer: cb); d.colorSpace = nil
            _ = try ctx.startTask(toRender: recipe(CIImage(cvPixelBuffer: frames[i])), from: e, to: d, at: .zero)
            cb.commit(); await cb.completed()
            if i > 0 { g += cb.gpuEndTime - cb.gpuStartTime }
        }
        print(String(format: "   %@: GPU %.2f ms", name as NSString, g / 40 * 1000))
    }
}

func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return r == KERN_SUCCESS ? Int(info.phys_footprint / 1_000_000) : -1
}
