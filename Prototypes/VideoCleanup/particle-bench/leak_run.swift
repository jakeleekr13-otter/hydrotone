// Mode "leak <variant>": 240 iterations of pool buffer -> render into it -> CIImage(cvPixelBuffer:) -> render out.
// Prints the memory footprint every 60 iterations. Variants: plain, clear (context.clearCaches every frame),
// sourceonly (render the decoded frame only, no pool).
import CoreImage
import CoreMedia
import Foundation

func leakTest(_ variant: String) async throws {
    let reader = try await Reader(fixtures + clipFiles["c3"]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: 30, seconds: 3)
    var frames: [CVPixelBuffer] = []
    while frames.count < 120, let f = reader.next() { frames.append(f.0) }
    reader.reader.cancelReading()
    let ctx = CIContext(), r = Renderer(ctx)
    var pool: CVPixelBufferPool?
    let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                                     kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                                     kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    var line: [String] = []
    for i in 0..<240 {
        let src = frames[i % 120]
        if variant == "sourceonly" { _ = r.render(CIImage(cvPixelBuffer: src).applyingGaussianBlur(sigma: 2).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), like: src) }
        else if variant == "arp" {
            autoreleasepool {
                var b: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &b)
                ctx.render(CIImage(cvPixelBuffer: src).applyingGaussianBlur(sigma: 0.8).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), to: b!, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), colorSpace: nil)
                let img = CIImage(cvPixelBuffer: b!, options: [.colorSpace: NSNull()])
                _ = r.render(img.applyingGaussianBlur(sigma: 2).cropped(to: img.extent), like: src)
            }
        } else if variant == "arpfirst" || variant == "arpsecond" {
            var img: CIImage?
            if variant == "arpfirst" {
                autoreleasepool {
                    var b: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &b)
                    ctx.render(CIImage(cvPixelBuffer: src).applyingGaussianBlur(sigma: 0.8).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), to: b!, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), colorSpace: nil)
                    img = CIImage(cvPixelBuffer: b!, options: [.colorSpace: NSNull()])
                }
                _ = r.render(img!.applyingGaussianBlur(sigma: 2).cropped(to: img!.extent), like: src)
            } else {
                var b: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &b)
                ctx.render(CIImage(cvPixelBuffer: src).applyingGaussianBlur(sigma: 0.8).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), to: b!, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), colorSpace: nil)
                img = CIImage(cvPixelBuffer: b!, options: [.colorSpace: NSNull()])
                autoreleasepool { _ = r.render(img!.applyingGaussianBlur(sigma: 2).cropped(to: img!.extent), like: src) }
            }
        } else {
            var b: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &b)
            ctx.render(CIImage(cvPixelBuffer: src).applyingGaussianBlur(sigma: 0.8).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), to: b!, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), colorSpace: nil)
            let img = CIImage(cvPixelBuffer: b!, options: [.colorSpace: NSNull()])
            _ = r.render(img.applyingGaussianBlur(sigma: 2).cropped(to: img.extent), like: src)
            if variant == "clear" { ctx.clearCaches() }
        }
        if i % 60 == 59 { line.append("\(footprintMB())MB") }
    }
    print("   leak \(variant):", line.joined(separator: " "))
}
