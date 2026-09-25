// Mode "peek <clip> <seconds> <x> <y> <w> <h> <name>": one decoded frame, a region at 1x with contrast x3, to find subjects.
import CoreImage
import Foundation

func peek(_ clip: String, _ t: Double, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ name: String) async throws {
    let reader = try await Reader(fixtures + clipFiles[clip]!, format: TemporalDenoiser.sourcePixelFormat(hdr: false), start: t, seconds: 0.1)
    guard let (b, time) = reader.next() else { return }
    let img = renderRGBA(CIImage(cvPixelBuffer: b), CIContext())
    savePNG(crop(img, x: x, y: y, w: w, h: h, scale: 1, stretch: 3), "\(root)/crops2/peek_\(name).png")
    print("peek \(name) at \(time.seconds) s")
}
