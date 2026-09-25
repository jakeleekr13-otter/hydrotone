// Mode "viz <clip> <seconds> <x> <y>": marks metric specks on a 320x180 crop (3x zoom) and prints peak histogram.
import CoreVideo
import CoreImage
import Foundation

func vizFrame(_ tag: String, _ sec: Double, _ cx: Int, _ cy: Int, _ m: MetricSettings = MetricSettings()) async throws {
    let reader = try await Reader(fixtures + clipFiles[tag]!, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, start: sec, seconds: 0.2)
    var bufs: [CVPixelBuffer] = []
    while bufs.count < 4, let (b, _) = reader.next() { bufs.append(b) }
    let luma = Luma(width: CVPixelBufferGetWidth(bufs[0]), height: CVPixelBufferGetHeight(bufs[0]))
    let w = luma.w, h = luma.h
    let ys = try [0, 1, 3].map { try luma.read(bufs[$0]) }
    let f = ys.map { maps($0, w, h, m) }
    let c = specks(f[1], prev: (f[0], motion(ys[1], ys[0], w, h)), next2: (f[2], motion(ys[1], ys[2], w, h)), m)
    let all = f[1].bright.filter { $0.size <= m.maxSpeckArea && $0.isolated }
    var hist = [Int](repeating: 0, count: 8)
    for b in c.driftingBlobs { hist[min(7, Int(b.peak / 2))] += 1 }
    for b in f[1].bright where b.size <= 60 && b.isolated && tag == "c3" && b.cx >= Float(cx) && b.cx < Float(cx + 320) && b.cy >= Float(cy) && b.cy < Float(cy + 180) {
        print("  blob crop(\(Int((b.cx - Float(cx)) * 3)),\(Int((b.cy - Float(cy)) * 3))) area \(b.area) size \(b.size) peak \(f2(Double(b.peak))) T \(f2(Double(f[1].t(Int(b.cx), Int(b.cy)))))")
    }
    print("\(tag) t=\(sec): specks \(all.count) drifting \(c.drifting) dots \(c.dots) driftingDots \(c.driftingDots); drifting peak histogram (levels, bins of 2): \(hist)")
    let ctx = CIContext()
    let img = renderRGBA(CIImage(cvPixelBuffer: bufs[1]), ctx)
    let cw = 320, ch = 180, s = 3
    var plain = crop(img, x: cx, y: cy, w: cw, h: ch, scale: s, stretch: 2)
    let raw = plain
    for b in c.driftingBlobs where b.cx >= Float(cx) && b.cx < Float(cx + cw) && b.cy >= Float(cy) && b.cy < Float(cy + ch) {
        let bx = Int((b.cx - Float(cx)) * Float(s)), by = Int((b.cy - Float(cy)) * Float(s))
        let col: [UInt8] = b.peak >= 6 ? [255, 40, 40] : (b.peak >= 3 ? [255, 220, 0] : [120, 120, 120])
        for d in -8...8 { for (xx, yy) in [(bx + d, by - 8), (bx + d, by + 8), (bx - 8, by + d), (bx + 8, by + d)] where xx >= 0 && yy >= 0 && xx < cw * s && yy < ch * s {
            let i = (yy * cw * s + xx) * 4; plain.bytes[i] = col[0]; plain.bytes[i + 1] = col[1]; plain.bytes[i + 2] = col[2]
        }}
    }
    savePNG(grid([[raw], [plain]]), "\(root)/look/viz_\(tag)_\(sec).png")
}

/// Mode "gallery <clip> <seconds>": 40x40 crops (4x) around up to 24 drifting specks and dots, strongest first.
/// Each tile: frame t-1 | t | t+2, aligned by the global shift, so the viewer can see if the speck moves.
func gallery(_ tag: String, _ sec: Double, _ m: MetricSettings = MetricSettings()) async throws {
    let reader = try await Reader(fixtures + clipFiles[tag]!, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, start: sec, seconds: 0.2)
    var bufs: [CVPixelBuffer] = []
    while bufs.count < 4, let (b, _) = reader.next() { bufs.append(b) }
    let luma = Luma(width: CVPixelBufferGetWidth(bufs[0]), height: CVPixelBufferGetHeight(bufs[0]))
    let w = luma.w, h = luma.h
    let ys = try [0, 1, 3].map { try luma.read(bufs[$0]) }
    let f = ys.map { maps($0, w, h, m) }
    let mp = motion(ys[1], ys[0], w, h), mn = motion(ys[1], ys[2], w, h)
    var picked: [(Blob, Bool)] = []
    for b in f[1].bright where b.size <= m.maxDotArea && b.isolated && b.peak <= m.maxPeak {
        let looks = [look(f[1], b, f[0], mp.at(b.cx, b.cy), m), look(f[1], b, f[2], mn.at(b.cx, b.cy), m)]
        picked.append((b, !looks.contains(.gone)))
    }
    let drifting = picked.filter { !$0.1 }.sorted { $0.0.peak > $1.0.peak }
    let ctx = CIContext()
    let imgs = [0, 1, 3].map { renderRGBA(CIImage(cvPixelBuffer: bufs[$0]), ctx) }
    var rows: [[RGBA]] = [], row: [RGBA] = []
    // Evenly spread picks over the peak ranking, not only the strongest.
    let n = min(24, drifting.count)
    let picks = n == 0 ? [] : (0..<n).map { drifting[$0 * drifting.count / n] }
    debugLook = true
    for (k, (b, _)) in picks.enumerated() where k < 12 { print("  tile \(k) at (\(Int(b.cx)),\(Int(b.cy))) size \(b.size)"); _ = look(f[1], b, f[0], mp.at(b.cx, b.cy), m); _ = look(f[1], b, f[2], mn.at(b.cx, b.cy), m) }
    debugLook = false
    for (b, _) in picks {
        for (k, off) in [(0, mp.at(b.cx, b.cy)), (1, SIMD2<Float>.zero), (2, mn.at(b.cx, b.cy))] {
            let x = min(w - 40, max(0, Int(b.cx + off.x) - 20)), y = min(h - 40, max(0, Int(b.cy + off.y) - 20))
            row.append(crop(imgs[k], x: x, y: y, w: 40, h: 40, scale: 3, stretch: 2))
        }
        if row.count == 12 { rows.append(row); row = [] }
    }
    if !row.isEmpty { while row.count < 12 { row.append(RGBA(w: 120, h: 120, bytes: [UInt8](repeating: 255, count: 120 * 120 * 4))) }; rows.append(row) }
    print("\(tag) t=\(sec): isolated small bright \(picked.count), drifting \(drifting.count); tiles (size, peak):", picks.map { "\($0.0.size)/\(Int($0.0.peak))" }.joined(separator: " "))
    if !rows.isEmpty { savePNG(grid(rows, gap: 4), "\(root)/look/gal_\(tag)_\(sec).png") }
}
