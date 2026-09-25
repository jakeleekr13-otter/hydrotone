import VideoToolbox
import CoreVideo
print("isSupported:", VTTemporalNoiseFilterConfiguration.isSupported)
let maxD = VTTemporalNoiseFilterConfiguration.maximumDimensions ?? CMVideoDimensions(width: -1, height: -1), minD = VTTemporalNoiseFilterConfiguration.minimumDimensions ?? CMVideoDimensions(width: -1, height: -1)
print("max:", maxD.width, "x", maxD.height, " min:", minD.width, "x", minD.height)
func fourcc(_ v: OSType) -> String { String(bytes: [24,16,8,0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)" }
print("supported formats:", VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats.map(fourcc))
for (w, h) in [(1920, 1080), (3840, 2160)] {
    for f in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA] {
        if let c = VTTemporalNoiseFilterConfiguration(frameWidth: w, frameHeight: h, sourcePixelFormat: f) {
            print("\(w)x\(h) \(fourcc(f)): previous=\(c.previousFrameCount) next=\(c.nextFrameCount)")
        } else { print("\(w)x\(h) \(fourcc(f)): config nil") }
    }
}
