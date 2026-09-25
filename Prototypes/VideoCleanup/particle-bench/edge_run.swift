// Mode "edges": frame count and order for clips of 0...6 frames, and for a size change mid-stream.
import CoreImage
import CoreMedia
import Foundation

func edgeTest() async throws {
    let reader = try await Reader(fixtures + clipFiles["c3"]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: 30, seconds: 0.2)
    var frames: [CVPixelBuffer] = []
    while frames.count < 6, let f = reader.next() { frames.append(f.0) }
    let ctx = CIContext()
    for n in 0...6 {
        let p = ParticleFilter(context: ctx)!
        var times: [Int64] = []
        for i in 0..<n { if let o = p.push(CIImage(cvPixelBuffer: frames[i]), at: CMTime(value: Int64(i), timescale: 60)) { times.append(o.time.value) } }
        times += p.finish().map(\.time.value)
        print("   \(n) frames in -> out \(times) \(times == Array(0..<Int64(n)) ? "OK" : "WRONG")")
    }
}
