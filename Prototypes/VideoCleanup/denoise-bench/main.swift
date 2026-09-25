// Mac benchmark for TemporalDenoiser. Build:
//   mkdir -p build && cp bench.swift build/main.swift
//   swiftc -O -swift-version 6 TemporalDenoiser.swift build/main.swift -o bench && ./bench [clip1_coral|clip2_anemone|clip3_school|hdr]
import Accelerate
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// Outputs go to HT_PROTO_OUT. Dive clips come from DeveloperMedia/; the HDR test clips from HydroToneTests/Fixtures/.
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let root = ProcessInfo.processInfo.environment["HT_PROTO_OUT"] ?? NSTemporaryDirectory() + "hydrotone-video-cleanup/denoise"
let fixtures = repo + "/HydroToneTests/Fixtures/"
let media = (ProcessInfo.processInfo.environment["HT_EVAL_DATA"] ?? repo + "/DeveloperMedia") + "/"
let strengths: [Float] = [0.25, 0.5, 0.75, 1.0]
let clipSeconds = 8.0
let cropFrame = 240          // 4 s into the 60 fps window
let cropW = 320, cropH = 240
let ci = CIContext(options: [.cacheIntermediates: false])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func fourcc(_ v: OSType) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)" }
func pct(_ a: Double, _ b: Double) -> String { b == 0 ? "n/a" : String(format: "%+.1f%%", (a - b) / b * 100) }
func f2(_ v: Double) -> String { String(format: "%.2f", v) }

// MARK: - Decoding

final class Reader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    init(_ path: String, format: OSType, start: Double, seconds: Double, size: (Int, Int)? = nil) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HydroBenchError.noTrack }
        reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                       kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        if let size { settings[kCVPixelBufferWidthKey as String] = size.0; settings[kCVPixelBufferHeightKey as String] = size.1 }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 60000))
        guard reader.startReading() else { throw reader.error ?? HydroBenchError.start }
    }
    func next() -> (CVPixelBuffer, CMTime)? {
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { return (buffer, CMSampleBufferGetPresentationTimeStamp(sample)) }
        }
        return nil
    }
}

enum HydroBenchError: Error { case noTrack, start, transfer }

/// Exact luma through VTPixelTransferSession into plain 420v / x420, in 8-bit code values (10-bit divided by 4).
final class Luma {
    let session: VTPixelTransferSession
    let target: CVPixelBuffer
    let tenBit: Bool
    let w: Int, h: Int
    init(width: Int, height: Int, tenBit: Bool) {
        var s: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
        session = s!
        var t: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &t)
        target = t!
        self.tenBit = tenBit; w = width; h = height
    }
    func plain(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard VTPixelTransferSessionTransferImage(session, from: buffer, to: target) == noErr else { throw HydroBenchError.transfer }
        return target
    }
    func read(_ buffer: CVPixelBuffer) throws -> [Float] {
        let p = try plain(buffer)
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(p, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                if tenBit {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<w { o[y * w + x] = Float(row[x] >> 6) / 4 }
                } else {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { o[y * w + x] = Float(row[x]) }
                }
            }
        }
        return out
    }
}

func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] {
    var dst = [Float](repeating: 0, count: w * h)
    let k = [Float](repeating: 1 / Float(2 * radius + 1), count: 2 * radius + 1)
    var s = src
    s.withUnsafeMutableBytes { sp in
        dst.withUnsafeMutableBytes { dp in
            var a = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var b = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            _ = vImageSepConvolve_PlanarF(&a, &b, nil, 0, 0, k, UInt32(k.count), k, UInt32(k.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
        }
    }
    return dst
}

// MARK: - Metrics

/// Region masks come from the ORIGINAL frame only, so every strength is scored on the same pixels.
struct Blocks {
    static let size = 16
    let gw: Int, gh: Int
    var flat: [Bool], textured: [Bool], staticFlat: [Bool], moving: [Bool]
    var texture: [Float], motion: [Float]

    init(blurred b: [Float], previous p: [Float]?, w: Int, h: Int) {
        let gw = w / Self.size, gh = h / Self.size
        self.gw = gw; self.gh = gh
        let n = gw * gh
        var texture = [Float](repeating: 0, count: n), motion = [Float](repeating: 0, count: n)
        b.withUnsafeBufferPointer { b in
            for by in 0..<gh { for bx in 0..<gw {
                var t: Float = 0, m: Float = 0
                for y in (by * Self.size)..<((by + 1) * Self.size) where y + 1 < h {
                    for x in (bx * Self.size)..<((bx + 1) * Self.size) where x + 1 < w {
                        let i = y * w + x
                        let dx = b[i + 1] - b[i], dy = b[i + w] - b[i]
                        t += dx * dx + dy * dy
                        if let p { m += abs(b[i] - p[i]) }
                    }
                }
                let c = Float(Self.size * Self.size)
                texture[by * gw + bx] = t / c; motion[by * gw + bx] = m / c
            }}
        }
        self.texture = texture; self.motion = motion
        let sortedT = texture.sorted(), sortedM = motion.sorted()
        let q25 = sortedT[n / 4], q75 = sortedT[n * 3 / 4], m90 = max(2, sortedM[n * 9 / 10])
        let hasPrevious = p != nil
        flat = texture.map { $0 <= q25 }
        textured = texture.map { $0 >= q75 }
        staticFlat = zip(flat, motion).map { $0 && hasPrevious && $1 <= 0.5 }
        moving = motion.map { hasPrevious && $0 >= m90 }
    }

    func forEach(_ mask: [Bool], _ w: Int, _ body: (Int) -> Void) {
        for by in 0..<gh { for bx in 0..<gw where mask[by * gw + bx] {
            for y in (by * Self.size)..<((by + 1) * Self.size) { for x in (bx * Self.size)..<((bx + 1) * Self.size) { body(y * w + x) } }
        }}
    }
}

struct Sums {
    var noise = 0.0, noiseN = 0.0, flicker = 0.0, flickerN = 0.0, sharp = 0.0, sharpN = 0.0
    var devMoving = 0.0, devMovingN = 0.0, devStatic = 0.0, devStaticN = 0.0
    var noiseRMS: Double { (noise / max(1, noiseN)).squareRoot() }
    var flickerRMS: Double { (flicker / max(1, flickerN)).squareRoot() }
    var sharpness: Double { sharp / max(1, sharpN) }
    var movingDev: Double { (devMoving / max(1, devMovingN)).squareRoot() }
    var staticDev: Double { (devStatic / max(1, devStaticN)).squareRoot() }
}

func score(_ y: [Float], previous: [Float]?, original: [Float]?, blocks: Blocks, w: Int, h: Int, into s: inout Sums) {
    let b = boxBlur(y, w, h, radius: 3)
    let s3 = boxBlur(y, w, h, radius: 1)
    y.withUnsafeBufferPointer { y in b.withUnsafeBufferPointer { b in s3.withUnsafeBufferPointer { s3 in
        blocks.forEach(blocks.flat, w) { i in let r = Double(y[i] - b[i]); s.noise += r * r; s.noiseN += 1 }
        if let previous {
            previous.withUnsafeBufferPointer { p in
                blocks.forEach(blocks.staticFlat, w) { i in let d = Double(y[i] - p[i]); s.flicker += d * d; s.flickerN += 1 }
            }
        }
        blocks.forEach(blocks.textured, w) { i in
            guard i + w + 1 < w * h else { return }
            let dx = Double(s3[i + 1] - s3[i]), dy = Double(s3[i + w] - s3[i]); s.sharp += dx * dx + dy * dy; s.sharpN += 1
        }
        if let original {
            original.withUnsafeBufferPointer { o in
                blocks.forEach(blocks.moving, w) { i in let d = Double(y[i] - o[i]); s.devMoving += d * d; s.devMovingN += 1 }
                blocks.forEach(blocks.staticFlat, w) { i in let d = Double(y[i] - o[i]); s.devStatic += d * d; s.devStaticN += 1 }
            }
        }
    }}}
}

// MARK: - Images

struct RGBA { let w: Int, h: Int; var bytes: [UInt8] }

func render(_ buffer: CVPixelBuffer) -> RGBA {
    let image = CIImage(cvPixelBuffer: buffer)
    let w = Int(image.extent.width), h = Int(image.extent.height)
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { ci.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: sRGB) }
    return RGBA(w: w, h: h, bytes: bytes)
}

func meanAbs(_ a: RGBA, _ b: RGBA) -> (mean: Double, max: Int) {
    var sum = 0, peak = 0, n = 0, big = 0
    var box = (Int.max, Int.max, -1, -1)
    for i in 0..<a.bytes.count where i % 4 != 3 {
        let d = abs(Int(a.bytes[i]) - Int(b.bytes[i])); sum += d; peak = max(peak, d); n += 1
        if d > 16 { big += 1; let p = i / 4, x = p % a.w, y = p / a.w; box = (min(box.0, x), min(box.1, y), max(box.2, x), max(box.3, y)) }
    }
    if big > 0 { print("    [diff>16: \(big) samples, box x \(box.0)-\(box.2) y \(box.1)-\(box.3)]") }
    return (Double(sum) / Double(n), peak)
}

/// Crop from a CI bitmap. CI bitmap row 0 is the top of the picture. `origin` uses top-left pixel coordinates.
/// `stretch` multiplies distance from `center` so faint noise is visible, like strong colour correction would show it.
func crop(_ img: RGBA, x: Int, y: Int, scale: Int = 2, stretch: Float = 1, center: [Float] = [128, 128, 128]) -> RGBA {
    var out = [UInt8](repeating: 255, count: cropW * scale * cropH * scale * 4)
    for yy in 0..<(cropH * scale) { for xx in 0..<(cropW * scale) {
        let s = ((y + yy / scale) * img.w + (x + xx / scale)) * 4, d = (yy * cropW * scale + xx) * 4
        for c in 0..<3 { out[d + c] = UInt8(max(0, min(255, (Float(img.bytes[s + c]) - center[c]) * stretch + center[c]))) }
    }}
    return RGBA(w: cropW * scale, h: cropH * scale, bytes: out)
}

func diff(_ a: RGBA, _ b: RGBA, gain: Int = 4) -> RGBA {
    var out = a.bytes
    for i in stride(from: 0, to: out.count, by: 4) {
        let d = (0..<3).map { abs(Int(a.bytes[i + $0]) - Int(b.bytes[i + $0])) }.max()! * gain
        out[i] = UInt8(min(255, d)); out[i + 1] = UInt8(min(255, d)); out[i + 2] = UInt8(min(255, d)); out[i + 3] = 255
    }
    return RGBA(w: a.w, h: a.h, bytes: out)
}

func meanColor(_ img: RGBA, x: Int, y: Int) -> [Float] {
    var s: [Float] = [0, 0, 0]
    for yy in 0..<cropH { for xx in 0..<cropW { let i = ((y + yy) * img.w + x + xx) * 4; for c in 0..<3 { s[c] += Float(img.bytes[i + c]) } } }
    return s.map { $0 / Float(cropW * cropH) }
}

func grid(_ rows: [[RGBA]], gap: Int = 8) -> RGBA {
    let cw = rows[0][0].w, ch = rows[0][0].h, cols = rows[0].count
    let w = cols * cw + (cols - 1) * gap, h = rows.count * ch + (rows.count - 1) * gap
    var out = [UInt8](repeating: 255, count: w * h * 4)
    for (r, row) in rows.enumerated() { for (c, img) in row.enumerated() {
        for y in 0..<ch {
            let d = ((r * (ch + gap) + y) * w + c * (cw + gap)) * 4
            out.replaceSubrange(d..<(d + cw * 4), with: img.bytes[(y * cw * 4)..<((y + 1) * cw * 4)])
        }
    }}
    return RGBA(w: w, h: h, bytes: out)
}

func savePNG(_ img: RGBA, _ path: String) {
    var bytes = img.bytes
    let cg = bytes.withUnsafeMutableBytes { p -> CGImage in
        let ctx = CGContext(data: p.baseAddress, width: img.w, height: img.h, bitsPerComponent: 8, bytesPerRow: img.w * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

/// Best window on the block grid: max motion (moving subject) or min texture (flat water).
func window(_ blocks: Blocks, values: [Float], maximize: Bool) -> (Int, Int) {
    let bw = cropW / Blocks.size, bh = cropH / Blocks.size
    var best: (Float, Int, Int) = (maximize ? -1 : .greatestFiniteMagnitude, 0, 0)
    for by in 0...(blocks.gh - bh) { for bx in 0...(blocks.gw - bw) {
        var s: Float = 0
        for y in by..<(by + bh) { for x in bx..<(bx + bw) { s += values[y * blocks.gw + x] } }
        if maximize ? s > best.0 : s < best.0 { best = (s, bx, by) }
    }}
    return (best.1 * Blocks.size, best.2 * Blocks.size)
}

// MARK: - Speed

func speed(_ path: String, format: OSType, hdr: Bool, size: (Int, Int)?, frames: Int, strengths: [Float]) async throws -> [(Float, Double, Double)] {
    let reader = try await Reader(path, format: format, start: 0, seconds: clipSeconds, size: size)
    var decoded: [(CVPixelBuffer, CMTime)] = []
    while decoded.count < frames, let f = reader.next() { decoded.append(f) }
    reader.reader.cancelReading()
    let w = CVPixelBufferGetWidth(decoded[0].0), h = CVPixelBufferGetHeight(decoded[0].0)
    var results: [(Float, Double, Double)] = []
    for s in strengths {
        let setupStart = Date()
        guard let d = TemporalDenoiser(width: w, height: h, hdr: hdr, strength: s) else { print("  speed: denoiser nil at \(w)x\(h)"); continue }
        let setup = Date().timeIntervalSince(setupStart)
        var out = 0
        let t0 = Date()
        for f in decoded { if await d.push(f.0, at: f.1) != nil { out += 1 } }
        out += await d.finish().count
        let t = Date().timeIntervalSince(t0)
        precondition(out == decoded.count, "frame count changed")
        if let e = d.failure { print("  speed failure:", e) }
        results.append((s, Double(decoded.count) / t, setup))
    }
    return results
}

// MARK: - Quality pass

struct ClipResult {
    let name: String
    var frames = 0
    var original = Sums()
    var filtered: [Sums] = Array(repeating: Sums(), count: strengths.count)
    var failures: [String] = []
    var outCounts: [Int] = Array(repeating: 0, count: strengths.count)
    var ciSource = (0.0, 0), ciFiltered: [(Double, Int)] = []
    var formats: [String] = []
}

func quality(_ name: String, path: String, tag: String) async throws -> ClipResult {
    var result = ClipResult(name: name)
    let format = TemporalDenoiser.sourcePixelFormat(hdr: false)
    let reader = try await Reader(path, format: format, start: 0, seconds: clipSeconds)
    guard let first = reader.next() else { throw HydroBenchError.start }
    let w = CVPixelBufferGetWidth(first.0), h = CVPixelBufferGetHeight(first.0)
    let luma = Luma(width: w, height: h, tenBit: false)
    let denoisers = strengths.compactMap { TemporalDenoiser(width: w, height: h, hdr: false, strength: $0) }
    precondition(denoisers.count == strengths.count, "denoiser nil")
    var pending: [(CVPixelBuffer, CMTime)] = []     // sources waiting for their filtered frame
    var prevO: [Float]? = nil, prevBO: [Float]? = nil
    var prevF: [[Float]?] = Array(repeating: nil, count: strengths.count)
    var index = 0
    var cropRows: [[RGBA]] = []

    func consume(_ outputs: [TemporalDenoiser.Frame]) throws {
        let (src, time) = pending.removeFirst()
        precondition(outputs.allSatisfy { $0.time == time }, "time mismatch")
        let yo = try luma.read(src)
        let bo = boxBlur(yo, w, h, radius: 3)
        let blocks = Blocks(blurred: bo, previous: prevBO, w: w, h: h)
        score(yo, previous: prevO, original: nil, blocks: blocks, w: w, h: h, into: &result.original)
        for (k, o) in outputs.enumerated() {
            let yf = try luma.read(o.buffer)
            score(yf, previous: prevF[k], original: yo, blocks: blocks, w: w, h: h, into: &result.filtered[k])
            prevF[k] = yf
        }
        if index == cropFrame {
            // Core Image check: compressed source vs plain 420v of the same pixels; filtered compressed vs its 420v copy.
            let srcImg = render(src)
            result.ciSource = meanAbs(srcImg, render(try copyPlain(luma, src)))
            let motion = window(blocks, values: blocks.motion, maximize: true)
            let flat = window(blocks, values: blocks.texture, maximize: false)
            let detail = window(blocks, values: blocks.texture, maximize: true)
            // Block rows count from the top of the buffer; CI bitmaps are top-down too.
            let center = meanColor(srcImg, x: flat.0, y: flat.1)
            for (k, o) in outputs.enumerated() {
                let img = render(o.buffer)
                result.ciFiltered.append(meanAbs(img, render(try copyPlain(luma, o.buffer))))
                result.formats.append(fourcc(CVPixelBufferGetPixelFormatType(o.buffer)))
                let bm = crop(srcImg, x: motion.0, y: motion.1), am = crop(img, x: motion.0, y: motion.1)
                let bf = crop(srcImg, x: flat.0, y: flat.1, stretch: 4, center: center), af = crop(img, x: flat.0, y: flat.1, stretch: 4, center: center)
                let bt = crop(srcImg, x: detail.0, y: detail.1), at = crop(img, x: detail.0, y: detail.1)
                let dm = diff(bm, am)
                savePNG(grid([[bm, am, dm], [bt, at, diff(bt, at)], [bf, af, diff(bf, af, gain: 1)]]), "\(root)/crops/\(tag)_s\(Int(strengths[k] * 100)).png")
                cropRows.append([crop(srcImg, x: motion.0, y: motion.1, scale: 1), crop(img, x: motion.0, y: motion.1, scale: 1), diff(crop(srcImg, x: motion.0, y: motion.1, scale: 1), crop(img, x: motion.0, y: motion.1, scale: 1)),
                                 crop(srcImg, x: flat.0, y: flat.1, scale: 1, stretch: 4, center: center), crop(img, x: flat.0, y: flat.1, scale: 1, stretch: 4, center: center)])
            }
            savePNG(grid(cropRows), "\(root)/crops/\(tag)_grid.png")
            print("  crop frame \(index) t=\(f2(time.seconds))s motion window x=\(motion.0) y=\(motion.1) texture window x=\(detail.0) y=\(detail.1) flat window x=\(flat.0) y=\(flat.1)")
        }
        prevO = yo; prevBO = bo
        index += 1
    }

    var next: (CVPixelBuffer, CMTime)? = first
    while let item = next {
        let (buffer, time) = item
        pending.append((buffer, time))
        var outs: [TemporalDenoiser.Frame] = []
        for d in denoisers { if let o = await d.push(buffer, at: time) { outs.append(o) } }
        if !outs.isEmpty { precondition(outs.count == denoisers.count); try autoreleasepool { try consume(outs) } }
        result.frames += 1
        next = reader.next()
    }
    var tails: [[TemporalDenoiser.Frame]] = []
    for d in denoisers { tails.append(await d.finish()) }
    for i in 0..<tails[0].count { try consume(tails.map { $0[i] }) }
    precondition(pending.isEmpty, "pending not empty")
    result.outCounts = Array(repeating: index, count: strengths.count)
    result.failures = denoisers.map { $0.failure.map { "\($0)" } ?? "none" }
    return result
}

func copyPlain(_ luma: Luma, _ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
    let p = try luma.plain(buffer)
    var copy: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(p), CVPixelBufferGetHeight(p), CVPixelBufferGetPixelFormatType(p),
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &copy)
    VTPixelTransferSessionTransferImage(luma.session, from: p, to: copy!)
    CVBufferPropagateAttachments(buffer, copy!)
    return copy!
}

/// Core Image check against an independent decode: the same frame decoded straight to plain 420v (or x420).
func independentDecodeCheck(_ path: String, hdr: Bool, frameIndex: Int) async throws -> (Double, Int) {
    let a = try await Reader(path, format: TemporalDenoiser.sourcePixelFormat(hdr: hdr), start: 0, seconds: clipSeconds)
    let b = try await Reader(path, format: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, start: 0, seconds: clipSeconds)
    for _ in 0..<frameIndex { _ = a.next(); _ = b.next() }
    guard let fa = a.next(), let fb = b.next(), fa.1 == fb.1 else { throw HydroBenchError.start }
    return meanAbs(render(fa.0), render(fb.0))
}

// MARK: - HDR

func hdrRun(_ file: String) async throws {
    let path = fixtures + file
    let reader = try await Reader(path, format: TemporalDenoiser.sourcePixelFormat(hdr: true), start: 0, seconds: clipSeconds)
    var frames: [(CVPixelBuffer, CMTime)] = []
    while let f = reader.next() { frames.append(f) }
    let w = CVPixelBufferGetWidth(frames[0].0), h = CVPixelBufferGetHeight(frames[0].0)
    print("HDR \(file): \(frames.count) frames \(w)x\(h) source \(fourcc(CVPixelBufferGetPixelFormatType(frames[0].0)))")
    let luma = Luma(width: w, height: h, tenBit: true)
    for s: Float in [0.5, 1.0] {
        guard let d = TemporalDenoiser(width: w, height: h, hdr: true, strength: s) else { print("  s=\(s): denoiser nil"); continue }
        var outs: [TemporalDenoiser.Frame] = []
        let t0 = Date()
        for f in frames { if let o = await d.push(f.0, at: f.1) { outs.append(o) } }
        outs += await d.finish()
        let t = Date().timeIntervalSince(t0)
        var so = Sums(), sf = Sums()
        var prevBO: [Float]? = nil
        var changed = 0.0
        for (i, o) in outs.enumerated() {
            let yo = try luma.read(frames[i].0), yf = try luma.read(o.buffer)
            let bo = boxBlur(yo, w, h, radius: 3)
            let blocks = Blocks(blurred: bo, previous: prevBO, w: w, h: h)
            score(yo, previous: nil, original: nil, blocks: blocks, w: w, h: h, into: &so)
            score(yf, previous: nil, original: yo, blocks: blocks, w: w, h: h, into: &sf)
            changed += zip(yo, yf).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(yo.count)
            prevBO = bo
        }
        let mid = outs.count / 2
        // Harness note: VTPixelTransferSession &xv0 -> x420 changes chroma (Y stays exact), so this copy is not a clean reference in 10-bit.
        let ciS = meanAbs(render(frames[mid].0), render(try copyPlain(luma, frames[mid].0)))
        print("    CI source compressed vs its x420 transfer copy (harness check): meanAbs \(String(format: "%.3f", ciS.0)) max \(ciS.1)")
        let ciD = meanAbs(render(outs[mid].buffer), render(frames[mid].0))
        print("    CI filtered vs CI source, same frame: meanAbs \(String(format: "%.3f", ciD.0)) max \(ciD.1)")
        let ciF = meanAbs(render(outs[mid].buffer), render(try copyPlain(luma, outs[mid].buffer)))
        print("  s=\(s): out \(outs.count)/\(frames.count) format \(fourcc(CVPixelBufferGetPixelFormatType(outs[mid].buffer))) fps \(f2(Double(frames.count) / t)) failure \(d.failure.map { "\($0)" } ?? "none")")
        print("    noise \(f2(so.noiseRMS)) -> \(f2(sf.noiseRMS)) (\(pct(sf.noiseRMS, so.noiseRMS))) sharp \(pct(sf.sharpness, so.sharpness)) mean|dY| \(f2(changed / Double(outs.count))) (8-bit units)")
        print("    CI filtered compressed vs its x420 copy: meanAbs \(String(format: "%.3f", ciF.0)) max \(ciF.1)")
        let attach = CVBufferCopyAttachments(outs[mid].buffer, .shouldPropagate) as? [String: Any] ?? [:]
        print("    output attachments: transfer=\(attach[kCVImageBufferTransferFunctionKey as String] ?? "nil") primaries=\(attach[kCVImageBufferColorPrimariesKey as String] ?? "nil")")
    }
    let ind = try await independentDecodeCheck(path, hdr: true, frameIndex: frames.count / 2)
    print("  CI compressed source vs independent x420 decode: meanAbs \(String(format: "%.3f", ind.0)) max \(ind.1)")
}

// MARK: - Main

try? FileManager.default.createDirectory(atPath: "\(root)/crops", withIntermediateDirectories: true)
print("isSupported \(TemporalDenoiser.isSupported)")
let clips = [("2017-01-08 01.21.36.MOV", "clip1_coral"), ("2019-05-05 18.37.02.MOV", "clip2_anemone"), ("VID_20230118_095241_0018.MP4", "clip3_school")]
let only = CommandLine.arguments.dropFirst().first
for (file, tag) in clips where only == nil || only == tag {
    let path = media + file
    print("== \(tag) (\(file)) window 0-\(Int(clipSeconds)) s")
    let native = try await speed(path, format: TemporalDenoiser.sourcePixelFormat(hdr: false), hdr: false, size: nil, frames: 120, strengths: strengths)
    for (s, fps, setup) in native { print("  speed native s=\(s): \(f2(fps)) fps (setup \(f2(setup * 1000)) ms)") }
    if tag == "clip1_coral" {
        let uhd = try await speed(path, format: TemporalDenoiser.sourcePixelFormat(hdr: false), hdr: false, size: (3840, 2160), frames: 60, strengths: [0.5, 1.0])
        for (s, fps, _) in uhd { print("  speed 4K-upscaled s=\(s): \(f2(fps)) fps") }
    }
    let r = try await quality(tag, path: path, tag: tag)
    print("  frames in \(r.frames) out \(r.outCounts) failures \(r.failures) formats \(r.formats)")
    print("  original: noise \(f2(r.original.noiseRMS)) flicker \(f2(r.original.flickerRMS)) (px \(Int(r.original.flickerN))) sharp \(f2(r.original.sharpness))")
    for (k, s) in strengths.enumerated() {
        let f = r.filtered[k]
        print("  s=\(s): noise \(f2(f.noiseRMS)) (\(pct(f.noiseRMS, r.original.noiseRMS))) flicker \(f2(f.flickerRMS)) (\(pct(f.flickerRMS, r.original.flickerRMS))) sharp \(f2(f.sharpness)) (\(pct(f.sharpness, r.original.sharpness))) devMoving \(f2(f.movingDev)) devStatic \(f2(f.staticDev)) movingPx \(Int(f.devMovingN))")
    }
    print("  CI compressed source vs its 420v copy: meanAbs \(String(format: "%.3f", r.ciSource.0)) max \(r.ciSource.1)")
    for (k, s) in strengths.enumerated() { print("  CI filtered s=\(s) vs its 420v copy: meanAbs \(String(format: "%.3f", r.ciFiltered[k].0)) max \(r.ciFiltered[k].1)") }
    let ind = try await independentDecodeCheck(path, hdr: false, frameIndex: cropFrame)
    print("  CI compressed source vs independent 420v decode: meanAbs \(String(format: "%.3f", ind.0)) max \(ind.1)")
}
if only == nil || only == "hdr" {
    try await hdrRun("hlg_10bit.mov")
    try await hdrRun("pq_10bit.mov")
}
