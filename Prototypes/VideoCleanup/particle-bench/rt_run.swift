// Mode "roundtrip": which Core Image render settings return the source luma unchanged.
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

func roundTrip() async throws {
    let reader = try await Reader(fixtures + clipFiles["c3"]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: 40, seconds: 0.1)
    let (b, _) = reader.next()!
    let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
    let l = Luma(width: w, height: h)
    let y0 = try l.read(b)
    let att = CVBufferCopyAttachments(b, .shouldPropagate) as? [String: Any] ?? [:]
    print("source attachments:", att.filter { $0.key.contains("Matrix") || $0.key.contains("Transfer") || $0.key.contains("Primaries") || $0.key.contains("ColorSpace") }.map { "\($0.key)=\($0.value)" })
    print("CIImage colorSpace:", CIImage(cvPixelBuffer: b).colorSpace.map { "\($0)" } ?? "nil")
    let r = Renderer(CIContext())
    func test(_ name: String, _ ctx: CIContext, _ cs: CGColorSpace?, propagate: Bool = true, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, source: CVPixelBuffer? = nil) throws {
        let out = r.buffer(w, h, format)
        let sb = source ?? b
        if propagate { CVBufferPropagateAttachments(b, out) }
        let img = CIImage(cvPixelBuffer: sb)
        ctx.render(img, to: out, bounds: img.extent, colorSpace: cs)
        let y1 = try l.read(out)
        var s = 0.0, a = 0.0, mx: Float = 0, n2 = 0
        for i in 0..<(w * h) { let d = y1[i] - y0[i]; s += Double(d); a += Double(abs(d)); mx = max(mx, abs(d)); if abs(d) > 2 { n2 += 1 } }
        print(String(format: "  %-48@ signed %+.3f abs %.3f max %.0f >2: %.3f%%", name as NSString, s / Double(w * h), a / Double(w * h), mx, 100 * Double(n2) / Double(w * h)))
    }
    let src = CIImage(cvPixelBuffer: b).colorSpace
    try test("default ctx, source colour space", CIContext(), src)
    try test("default ctx, nil colour space", CIContext(), nil)
    try test("default ctx, 709 colour space", CIContext(), CGColorSpace(name: CGColorSpace.itur_709))
    try test("default ctx, sRGB", CIContext(), CGColorSpace(name: CGColorSpace.sRGB))
    try test("float working format, source cs", CIContext(options: [.workingFormat: CIFormat.RGBAf]), src)
    try test("no colour management", CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]), nil)
    try test("default ctx, source cs, no attachments", CIContext(), src, propagate: false)
    try test("to BGRA then transfer to 420v", CIContext(), src, format: kCVPixelFormatType_32BGRA)
    let plain = r.buffer(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    VTPixelTransferSessionTransferImage(r.transfer, from: b, to: plain); CVBufferPropagateAttachments(b, plain)
    try test("source as plain 420v, to 420v", CIContext(), src, source: plain)
    try test("to x420 (10-bit)", CIContext(), src, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
}
