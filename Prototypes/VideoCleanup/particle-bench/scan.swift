// Mode "scan": particle metric every 0.5 s across whole clips. Mode "noise": metric on pure synthetic noise.
import CoreVideo
import Foundation

func scanClip(_ tag: String) async throws {
    let path = fixtures + clipFiles[tag]!
    let reader = try await Reader(path, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, start: 0, seconds: 100)
    var ring: [(CVPixelBuffer, Double)] = []
    var j = 0
    var luma: Luma?
    let m = MetricSettings()
    while let (b, t) = reader.next() {
        ring.append((b, t.seconds)); if ring.count > 4 { ring.removeFirst() }
        let i = j - 2
        if i >= 1, i % 30 == 0, ring.count == 4 {
            if luma == nil { luma = Luma(width: CVPixelBufferGetWidth(b), height: CVPixelBufferGetHeight(b)) }
            let w = luma!.w, h = luma!.h
            let yp = try luma!.read(ring[0].0), yc = try luma!.read(ring[1].0), yn = try luma!.read(ring[3].0)
            let fp = maps(yp, w, h, m), fc = maps(yc, w, h, m), fn = maps(yn, w, h, m)
            let fp_ = motion(yc, yp, w, h), fn_ = motion(yc, yn, w, h)
            let sp = fp_.at(960, 540), sn = fn_.at(960, 540)
            let c = specks(fc, prev: (fp, fp_), next2: (fn, fn_), m)
            let sub = fc.bright.filter { $0.size > m.maxDotArea }.count + fc.dark.filter { $0.size > m.maxSpeckArea }.count
            print("\(tag) t=\(f2(ring[1].1)) brightSpots \(c.brightSpots) specks \(c.all) drifting \(c.drifting) static \(c.staticCount) attached \(c.attached) dots \(c.dots) driftingDots \(c.driftingDots) subjects \(sub) shiftPrev (\(f2(Double(sp.x))),\(f2(Double(sp.y)))) shiftNext2 (\(f2(Double(sn.x))),\(f2(Double(sn.y))))")
        }
        j += 1
    }
}

func noiseCheck() {
    let w = 1920, h = 1080
    var gen = SystemRandomNumberGenerator()
    for sigma: Float in [0.5, 1, 2, 4] {
        var y = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let u1 = Float.random(in: 1e-7..<1, using: &gen), u2 = Float.random(in: 0..<1, using: &gen)
            y[i] = 80 + sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let f = maps(y, w, h, MetricSettings())
        print("noise sigma \(sigma): bright groups \(f.bright.count) specks<=12 \(f.bright.filter { $0.size <= 12 }.count) T median \(f2(Double(f.threshold.sorted()[f.threshold.count / 2])))")
    }
}
