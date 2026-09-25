import CoreMedia
import CoreVideo
import VideoToolbox

/// Apple's hardware temporal noise filter (VTTemporalNoiseFilter) for video export.
///
/// Streaming use: `push` each decoded frame in presentation order, write every frame it returns,
/// then call `finish` once after the last frame and write what it returns.
/// A frame comes out once `nextFrameCount` (2) later frames have arrived, so output lags input by 2 frames.
/// Every output keeps its source presentation time. Frame count and order never change.
///
/// Edges:
/// - The first frame is sent with `hasDiscontinuity` and no previous reference.
/// - `finish` filters the last frames with the look-ahead that exists (1, then 0 next frames).
///   The filter needs at least one reference, past or future, so a one-frame clip is returned unfiltered.
/// - After a processing error the rest of the clip passes through unfiltered and `failure` keeps the error.
///
/// Sources must use `sourcePixelFormat(hdr:)`. Frames of any other format or size pass through unfiltered.
/// Not thread-safe: own one instance per export and call it from one task.
final class TemporalDenoiser {
    struct Frame {
        let buffer: CVPixelBuffer
        let time: CMTime
    }

    /// Compressed 4:2:0 video-range formats. Plain 420v, x420 and BGRA are rejected by the filter.
    static func sourcePixelFormat(hdr: Bool) -> OSType {
        hdr ? kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
            : kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
    }

    /// Hardware support only. The iOS simulator has no frame processor.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        VTTemporalNoiseFilterConfiguration.isSupported
        #endif
    }

    let width: Int
    let height: Int
    let pixelFormat: OSType
    let strength: Float
    private(set) var failure: Error?

    #if !targetEnvironment(simulator)
    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool
    private let previousCount: Int
    private let nextCount: Int
    /// Source frames in presentation order: up to `previousCount` already-filtered frames, then the unfiltered ones.
    private var window: [Frame] = []
    /// Index in `window` of the next frame to filter.
    private var cursor = 0
    private var started = false
    #endif

    /// Returns nil when the device lacks the filter, the size is out of range, or setup fails.
    /// The caller then passes frames through unchanged.
    init?(width: Int, height: Int, hdr: Bool, strength: Float) {
        #if targetEnvironment(simulator)
        return nil
        #else
        let format = Self.sourcePixelFormat(hdr: hdr)
        guard VTTemporalNoiseFilterConfiguration.isSupported,
              let low = VTTemporalNoiseFilterConfiguration.minimumDimensions,
              let high = VTTemporalNoiseFilterConfiguration.maximumDimensions,
              width >= Int(low.width), height >= Int(low.height),
              width <= Int(high.width), height <= Int(high.height),
              let configuration = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height,
                                                                     sourcePixelFormat: format),
              configuration.supportedPixelFormats.contains(format) else { return nil }
        var attributes = configuration.destinationPixelBufferAttributes
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created else { return nil }
        do { try processor.startSession(configuration: configuration) } catch { return nil }
        self.width = width
        self.height = height
        self.pixelFormat = format
        self.strength = min(1, max(0, strength))
        pool = created
        previousCount = max(0, configuration.previousFrameCount ?? 1)
        nextCount = max(0, configuration.nextFrameCount ?? 2)
        #endif
    }

    deinit {
        #if !targetEnvironment(simulator)
        processor.endSession()
        #endif
    }

    /// Adds one source frame. Returns the frame that is now ready, or nil while the look-ahead fills.
    func push(_ buffer: CVPixelBuffer, at time: CMTime) async -> Frame? {
        #if targetEnvironment(simulator)
        return Frame(buffer: buffer, time: time)
        #else
        window.append(Frame(buffer: buffer, time: time))
        guard window.count - cursor > nextCount else { return nil }
        return await emit()
        #endif
    }

    /// Flushes the look-ahead. Call once after the last `push`; the instance is spent afterwards.
    func finish() async -> [Frame] {
        #if targetEnvironment(simulator)
        return []
        #else
        var frames: [Frame] = []
        while cursor < window.count { frames.append(await emit()) }
        window.removeAll()
        cursor = 0
        return frames
        #endif
    }

    #if !targetEnvironment(simulator)
    private func emit() async -> Frame {
        let source = window[cursor]
        let previous = Array(window[max(0, cursor - previousCount)..<cursor])
        let next = Array(window[(cursor + 1)..<min(window.count, cursor + 1 + nextCount)])
        let output = await filtered(source, previous: previous, next: next) ?? source
        cursor += 1
        let drop = max(0, cursor - previousCount)
        if drop > 0 { window.removeFirst(drop); cursor -= drop }
        return output
    }

    private func filtered(_ source: Frame, previous: [Frame], next: [Frame]) async -> Frame? {
        guard failure == nil, !(previous.isEmpty && next.isEmpty), accepts(source.buffer),
              (previous + next).allSatisfy({ accepts($0.buffer) }) else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess, let destination,
              let sourceFrame = VTFrameProcessorFrame(buffer: source.buffer, presentationTimeStamp: source.time),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: source.time)
        else { return nil }
        let previousFrames = previous.compactMap { VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: $0.time) }
        let nextFrames = next.compactMap { VTFrameProcessorFrame(buffer: $0.buffer, presentationTimeStamp: $0.time) }
        guard previousFrames.count == previous.count, nextFrames.count == next.count,
              let parameters = VTTemporalNoiseFilterParameters(sourceFrame: sourceFrame, nextFrames: nextFrames,
                  previousFrames: previousFrames, destinationFrame: destinationFrame,
                  filterStrength: strength, hasDiscontinuity: !started) else { return nil }
        started = true
        do {
            let _: any VTFrameProcessorParameters = try await processor.process(parameters: parameters)
        } catch {
            failure = error
            return nil
        }
        CVBufferPropagateAttachments(source.buffer, destination)
        return Frame(buffer: destination, time: source.time)
    }

    private func accepts(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(buffer) == pixelFormat
            && CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height
    }
    #endif
}
