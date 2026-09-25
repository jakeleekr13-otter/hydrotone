// Shared bench helpers. Reader, Luma and boxBlur are copied from ../denoise/bench.swift.
import Accelerate
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// Outputs (crops, logs) go to HT_PROTO_OUT; the clips come from DeveloperMedia/ at the repo root.
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
let root = ProcessInfo.processInfo.environment["HT_PROTO_OUT"] ?? NSTemporaryDirectory() + "hydrotone-video-cleanup/particles"
let fixtures = (ProcessInfo.processInfo.environment["HT_EVAL_DATA"] ?? repo + "/DeveloperMedia") + "/"
let clipFiles = ["c1": "2017-01-08 01.21.36.MOV", "c2": "2019-05-05 18.37.02.MOV", "c3": "VID_20230118_095241_0018.MP4"]
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func f2(_ v: Double) -> String { String(format: "%.2f", v) }
func pct(_ a: Double, _ b: Double) -> String { b == 0 ? "n/a" : String(format: "%+.1f%%", (a - b) / b * 100) }

enum BenchError: Error { case noTrack, start, transfer }

final class Reader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    /// `size` makes the reader scale every frame, as the denoise bench did for its 4K speed runs.
    init(_ path: String, format: OSType, start: Double, seconds: Double, size: (Int, Int)? = nil) async throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw BenchError.noTrack }
        reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                       kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        if let size { settings[kCVPixelBufferWidthKey as String] = size.0; settings[kCVPixelBufferHeightKey as String] = size.1 }
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 60000))
        guard reader.startReading() else { throw reader.error ?? BenchError.start }
    }
    func next() -> (CVPixelBuffer, CMTime)? {
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) { return (buffer, CMSampleBufferGetPresentationTimeStamp(sample)) }
        }
        return nil
    }
}

/// Exact 8-bit luma through VTPixelTransferSession into plain 420v.
final class Luma {
    let session: VTPixelTransferSession
    let target: CVPixelBuffer
    let w: Int, h: Int
    init(width: Int, height: Int) {
        var s: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
        session = s!
        var t: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &t)
        target = t!
        w = width; h = height
    }
    func read(_ buffer: CVPixelBuffer) throws -> [Float] {
        let p: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { p = buffer } else {
            guard VTPixelTransferSessionTransferImage(session, from: buffer, to: target) == noErr else { throw BenchError.transfer }
            p = target
        }
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(p, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
        var out = [Float](repeating: 0, count: w * h)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { o[y * w + x] = Float(row[x]) }
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

/// Box downsample by an integer factor.
func downsample(_ src: [Float], _ w: Int, _ h: Int, by f: Int) -> ([Float], Int, Int) {
    let ow = w / f, oh = h / f
    var out = [Float](repeating: 0, count: ow * oh)
    let inv = 1 / Float(f * f)
    src.withUnsafeBufferPointer { s in
        for y in 0..<oh { for x in 0..<ow {
            var sum: Float = 0
            for yy in 0..<f { let r = (y * f + yy) * w + x * f; for xx in 0..<f { sum += s[r + xx] } }
            out[y * ow + x] = sum * inv
        }}
    }
    return (out, ow, oh)
}

// MARK: - Images

struct RGBA { let w: Int, h: Int; var bytes: [UInt8] }

func renderRGBA(_ image: CIImage, _ ctx: CIContext) -> RGBA {
    let e = image.extent
    let w = Int(e.width), h = Int(e.height)
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: sRGB) }
    return RGBA(w: w, h: h, bytes: bytes)
}

/// Top-left pixel coordinates. `scale` is nearest-neighbour zoom. `stretch` multiplies distance from the crop mean.
func crop(_ img: RGBA, x: Int, y: Int, w cw: Int, h ch: Int, scale: Int = 3, stretch: Float = 1) -> RGBA {
    var mean: [Float] = [0, 0, 0]
    for yy in 0..<ch { for xx in 0..<cw { let i = ((y + yy) * img.w + x + xx) * 4; for c in 0..<3 { mean[c] += Float(img.bytes[i + c]) } } }
    mean = mean.map { $0 / Float(cw * ch) }
    var out = [UInt8](repeating: 255, count: cw * scale * ch * scale * 4)
    for yy in 0..<(ch * scale) { for xx in 0..<(cw * scale) {
        let s = ((y + yy / scale) * img.w + (x + xx / scale)) * 4, d = (yy * cw * scale + xx) * 4
        for c in 0..<3 { out[d + c] = UInt8(max(0, min(255, (Float(img.bytes[s + c]) - mean[c]) * stretch + mean[c]))) }
    }}
    return RGBA(w: cw * scale, h: ch * scale, bytes: out)
}

func diffImage(_ a: RGBA, _ b: RGBA, gain: Int = 4) -> RGBA {
    var out = a.bytes
    for i in stride(from: 0, to: out.count, by: 4) {
        let d = min(255, (0..<3).map { abs(Int(a.bytes[i + $0]) - Int(b.bytes[i + $0])) }.max()! * gain)
        out[i] = UInt8(d); out[i + 1] = UInt8(d); out[i + 2] = UInt8(d); out[i + 3] = 255
    }
    return RGBA(w: a.w, h: a.h, bytes: out)
}

func grid(_ rows: [[RGBA]], gap: Int = 6) -> RGBA {
    let cw = rows[0][0].w, ch = rows[0][0].h, cols = rows.map(\.count).max()!
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
