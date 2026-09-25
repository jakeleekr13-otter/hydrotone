// Mode "cmp <clip> <start> <seconds>": new ParticleFilter vs the V1 reference (CPU motion), frame by frame.
// Both outputs go through the same 420v render. Reports luma pixels that differ and the largest difference.
import CoreImage
import CoreMedia
import Foundation

func compareWithV1(_ clip: String, _ start: Double, _ seconds: Double) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: start, seconds: seconds)
    let ctx = CIContext()
    let r = Renderer(ctx)
    let old = ParticleFilterV1(context: ctx)!, new = ParticleFilter(context: ctx)!
    var sources: [CMTime: CVPixelBuffer] = [:]
    var oldOut: [CMTime: [Float]] = [:], newOut: [CMTime: [Float]] = [:]
    var luma: Luma?
    var frames = 0, differingFrames = 0, differing = 0, maxDiff: Float = 0, over2 = 0
    func check(_ t: CMTime) {
        guard let a = oldOut[t], let b = newOut[t] else { return }
        var n = 0
        for i in a.indices { let d = abs(a[i] - b[i]); if d > 0 { n += 1 }; if d > 2 { over2 += 1 }; maxDiff = max(maxDiff, d) }
        frames += 1; differing += n; if n > 0 { differingFrames += 1 }
        oldOut[t] = nil; newOut[t] = nil; sources[t] = nil
    }
    while let (b, t) = reader.next() {
        if luma == nil { luma = Luma(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b)) }
        sources[t] = b
        let img = CIImage(cvPixelBuffer: b)
        if let o = old.push(img, at: t) { oldOut[o.time] = try luma!.read(r.render(o.image, like: sources[o.time]!)) }
        if let o = new.push(img, at: t) { newOut[o.time] = try luma!.read(r.render(o.image, like: sources[o.time]!)); check(o.time) }
    }
    for o in old.finish() { oldOut[o.time] = try luma!.read(r.render(o.image, like: sources[o.time]!)) }
    for o in new.finish() { newOut[o.time] = try luma!.read(r.render(o.image, like: sources[o.time]!)); check(o.time) }
    print("== cmp \(clip) \(start) s + \(seconds) s: frames \(frames), frames with any difference \(differingFrames), differing luma px \(differing) (\(over2) over 2 levels), max diff \(maxDiff) levels")
}
