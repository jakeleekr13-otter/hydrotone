// Mode "removed <clip> <seconds> [n]": what the particle filter changed on one frame, strongest change first.
// Each tile: before | after, 40x40 px at 3x, contrast x2.
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

func removedGallery(_ clip: String, _ sec: Double, _ count: Int) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: sec - 0.05, seconds: 0.2)
    var frames: [(CVPixelBuffer, CMTime)] = []
    while frames.count < 7, let f = reader.next() { frames.append(f) }
    let ctx = CIContext(), r = Renderer(ctx)
    let pf = ParticleFilter(context: ctx)!
    var outs: [ParticleFilter.Frame] = []
    for f in frames { if let o = pf.push(CIImage(cvPixelBuffer: f.0), at: f.1) { outs.append(o) } }
    outs += pf.finish()
    let k = 3
    let src = frames[k].0
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    let l = Luma(width: w, height: h)
    let ya = try l.read(r.render(CIImage(cvPixelBuffer: src), like: src)), yc = try l.read(r.render(outs[k].image, like: src))
    var mark = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) where ya[i] - yc[i] > 2 { mark[i] = 1 }
    var groups: [(Float, Int, Int, Int)] = []   // (max drop, x, y, area)
    for s in 0..<(w * h) where mark[s] == 1 {
        var stack = [s]; mark[s] = 2
        var best: Float = 0, bx = 0, by = 0, area = 0
        while let i = stack.popLast() {
            area += 1
            let d = ya[i] - yc[i]; if d > best { best = d; bx = i % w; by = i / w }
            for dy in -1...1 { for dx in -1...1 { let x = i % w + dx, y = i / w + dy
                if x >= 0, y >= 0, x < w, y < h, mark[y * w + x] == 1 { mark[y * w + x] = 2; stack.append(y * w + x) } } }
        }
        groups.append((best, bx, by, area))
    }
    groups.sort { $0.0 > $1.0 }
    let before = renderRGBA(CIImage(cvPixelBuffer: src), ctx), after = renderRGBA(outs[k].image, ctx)
    var rows: [[RGBA]] = [], row: [RGBA] = []
    for g in groups.prefix(count) {
        let x = min(w - 40, max(0, g.1 - 20)), y = min(h - 40, max(0, g.2 - 20))
        row.append(crop(before, x: x, y: y, w: 40, h: 40, scale: 3, stretch: 2)); row.append(crop(after, x: x, y: y, w: 40, h: 40, scale: 3, stretch: 2))
        if row.count == 12 { rows.append(row); row = [] }
    }
    if !row.isEmpty { rows.append(row) }
    let drops = groups.map { $0.0 }
    print("\(clip) t=\(sec): changed groups \(groups.count), drop >30 \(drops.filter { $0 > 30 }.count), 10-30 \(drops.filter { $0 > 10 && $0 <= 30 }.count), <=10 \(drops.filter { $0 <= 10 }.count); tiles (drop/area@x,y):",
          groups.prefix(count).map { "\(Int($0.0))/\($0.3)@\($0.1),\($0.2)" }.joined(separator: " "))
    if !rows.isEmpty { savePNG(grid(rows, gap: 4), "\(root)/look/removed_\(clip)_\(sec).png") }
}
