import VideoToolbox
import CoreVideo
func code(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
func fourcc(_ v: OSType) -> String { String(bytes: [24,16,8,0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)" }
let names: [(String, OSType)] = [("Lossless_420YpCbCr8BiPlanarVideoRange", kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange),
    ("Lossless_420YpCbCr10PackedBiPlanarVideoRange", kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange),
    ("Lossy_420YpCbCr8BiPlanarVideoRange", kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange),
    ("Lossy_420YpCbCr10PackedBiPlanarVideoRange", kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange)]
for (n, f) in names { print(n, "=", fourcc(f)) }
for (w, h) in [(1920, 1080), (3840, 2160)] {
    for f in ["&8v0", "&xv0", "-8v0", "-xv0"] {
        if let c = VTTemporalNoiseFilterConfiguration(frameWidth: w, frameHeight: h, sourcePixelFormat: code(f)) {
            print("\(w)x\(h) \(f): previous=\(c.previousFrameCount) next=\(c.nextFrameCount)")
        } else { print("\(w)x\(h) \(f): config nil") }
    }
}
