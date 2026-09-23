import AVFoundation
import CoreImage
import CoreML
import Metal
import VideoToolbox
import os

enum DepthComputePolicy: String, Codable, Sendable, CaseIterable {
    case all
    case cpuAndNeuralEngine

    var coreML: MLComputeUnits {
        switch self {
        case .all: .all
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        }
    }
}

enum DevicePerformanceClass: String, Codable, Sendable {
    case conservative, balanced, high
}

struct DeviceCapabilityProfile: Codable, Sendable, Equatable {
    let performanceClass: DevicePerformanceClass
    let preferredComputePolicy: DepthComputePolicy
    let measuredDepthMilliseconds: Double?
    let allComputeMilliseconds: Double?
    let neuralEngineMilliseconds: Double?
    let supportsDynamicMetalLibraries: Bool
    let supportsHardwareHEVCDecode: Bool
    let supportsHardwareHEVCEncode: Bool
    let physicalMemoryBytes: UInt64
    let cacheVersion: Int

    static var conservative: Self {
        Self(performanceClass: .conservative, preferredComputePolicy: .all,
             measuredDepthMilliseconds: nil, allComputeMilliseconds: nil, neuralEngineMilliseconds: nil,
             supportsDynamicMetalLibraries: false,
             supportsHardwareHEVCDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
             supportsHardwareHEVCEncode: hardwareHEVCEncoderAvailable(),
             physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, cacheVersion: 1)
    }
}

actor DeviceCapabilityProfiler {
    private struct Cache: Codable {
        let systemMajorVersion: Int
        let profile: DeviceCapabilityProfile
    }
    private static let cacheKey = "HydroTone.VideoV2.DeviceProfile.v1"
    private let defaults: UserDefaults
    private var benchmarkInProgress = false
    #if DEBUG
    private let logger = Logger(subsystem: "com.hydrotone.app", category: "video-policy")
    #endif

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func profile(representativeImage: CIImage) async -> DeviceCapabilityProfile {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(Cache.self, from: data),
           cached.systemMajorVersion == major, cached.profile.cacheVersion == 1 {
            return cached.profile
        }
        let metal = MTLCreateSystemDefaultDevice()
        var timings: [DepthComputePolicy: Double] = [:]
        if let estimate = try? await DepthEstimator(computeUnits: MLComputeUnits.all).monocularDepth(for: representativeImage),
           let milliseconds = estimate.inferenceMilliseconds, milliseconds.isFinite {
            timings[.all] = milliseconds
        }
        // The first clip uses this safe provisional result. The second compute mode is
        // measured after preview analysis so model loading never blocks the first image.
        let preferred = DepthComputePolicy.all
        let measured = timings[preferred]
        let memory = ProcessInfo.processInfo.physicalMemory
        let performance: DevicePerformanceClass
        if let measured, measured < 45, memory >= 5_000_000_000 { performance = .high }
        else if let measured, measured < 90, memory >= 3_000_000_000 { performance = .balanced }
        else { performance = .conservative }
        let result = DeviceCapabilityProfile(
            performanceClass: performance, preferredComputePolicy: preferred,
            measuredDepthMilliseconds: measured, allComputeMilliseconds: timings[.all],
            neuralEngineMilliseconds: timings[.cpuAndNeuralEngine],
            supportsDynamicMetalLibraries: metal?.supportsDynamicLibraries ?? false,
            supportsHardwareHEVCDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            supportsHardwareHEVCEncode: hardwareHEVCEncoderAvailable(),
            physicalMemoryBytes: memory, cacheVersion: 1)
        if let data = try? JSONEncoder().encode(Cache(systemMajorVersion: major, profile: result)) {
            defaults.set(data, forKey: Self.cacheKey)
        }
        #if DEBUG
        logger.debug("class=\(performance.rawValue, privacy: .public) compute=\(preferred.rawValue, privacy: .public) inferenceMS=\(measured ?? -1) metalDynamic=\(result.supportsDynamicMetalLibraries)")
        #endif
        return result
    }

    func completeBenchmarkIfNeeded(representativeImage: CIImage) async {
        guard !benchmarkInProgress else { return }
        benchmarkInProgress = true
        defer { benchmarkInProgress = false }
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let data = defaults.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode(Cache.self, from: data),
              cached.systemMajorVersion == major,
              cached.profile.neuralEngineMilliseconds == nil else { return }
        guard let estimate = try? await DepthEstimator(computeUnits: MLComputeUnits.cpuAndNeuralEngine)
            .monocularDepth(for: representativeImage),
              let neural = estimate.inferenceMilliseconds, neural.isFinite else { return }
        let all = cached.profile.allComputeMilliseconds
        let preferred: DepthComputePolicy = all.map { neural < $0 ? .cpuAndNeuralEngine : .all } ?? .cpuAndNeuralEngine
        let measured = preferred == .cpuAndNeuralEngine ? neural : all
        let performance: DevicePerformanceClass
        if let measured, measured < 45, cached.profile.physicalMemoryBytes >= 5_000_000_000 { performance = .high }
        else if let measured, measured < 90, cached.profile.physicalMemoryBytes >= 3_000_000_000 { performance = .balanced }
        else { performance = .conservative }
        let updated = DeviceCapabilityProfile(
            performanceClass: performance, preferredComputePolicy: preferred,
            measuredDepthMilliseconds: measured, allComputeMilliseconds: all,
            neuralEngineMilliseconds: neural,
            supportsDynamicMetalLibraries: cached.profile.supportsDynamicMetalLibraries,
            supportsHardwareHEVCDecode: cached.profile.supportsHardwareHEVCDecode,
            supportsHardwareHEVCEncode: cached.profile.supportsHardwareHEVCEncode,
            physicalMemoryBytes: cached.profile.physicalMemoryBytes,
            cacheVersion: cached.profile.cacheVersion)
        if let encoded = try? JSONEncoder().encode(Cache(systemMajorVersion: major, profile: updated)) {
            defaults.set(encoded, forKey: Self.cacheKey)
        }
        #if DEBUG
        logger.debug("background-benchmark allMS=\(all ?? -1) neuralMS=\(neural) selected=\(preferred.rawValue, privacy: .public)")
        #endif
    }
}

private func hardwareHEVCEncoderAvailable() -> Bool {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[CFString: Any]] else { return false }
    return encoders.contains { encoder in
        let codec = (encoder[kVTVideoEncoderList_CodecType] as? NSNumber)?.uint32Value
        let hardware = (encoder[kVTVideoEncoderList_IsHardwareAccelerated] as? NSNumber)?.boolValue ?? false
        return codec == kCMVideoCodecType_HEVC && hardware
    }
}

enum VideoSourceWorkload: String, Sendable, Equatable {
    case light, medium, heavy
}

struct VideoSourceProfile: Sendable, Equatable {
    let duration: Double
    let displaySize: CGSize
    let frameRate: Float
    let codec: String
    let bitDepth: Int?
    let dynamicRange: VideoMetadata.DynamicRange
    let approximateBitsPerSecond: Double?
    let workload: VideoSourceWorkload

    static func make(url: URL, metadata: VideoMetadata) -> Self {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init)
        let bitrate = bytes.flatMap { metadata.duration > 0 ? $0 * 8 / metadata.duration : nil }
        let pixelsPerSecond = metadata.displaySize.width * metadata.displaySize.height
            * Double(max(1, metadata.frameRate)) * (metadata.isHDR ? 1.35 : 1)
        let workload: VideoSourceWorkload
        if pixelsPerSecond > 3840 * 2160 * 40 { workload = .heavy }
        else if pixelsPerSecond > 1920 * 1080 * 40 || metadata.isHDR { workload = .medium }
        else { workload = .light }
        return Self(duration: metadata.duration, displaySize: metadata.displaySize, frameRate: metadata.frameRate,
                    codec: metadata.codec, bitDepth: metadata.bitDepth, dynamicRange: metadata.dynamicRange,
                    approximateBitsPerSecond: bitrate, workload: workload)
    }
}

enum RuntimeThermalState: Int, Sendable, Equatable {
    case nominal, fair, serious, critical

    init(_ value: ProcessInfo.ThermalState) {
        switch value {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

struct RuntimeSystemState: Sendable, Equatable {
    var thermalState: RuntimeThermalState
    var observedProcessingFPS: Double?

    static var current: Self {
        Self(thermalState: RuntimeThermalState(ProcessInfo.processInfo.thermalState), observedProcessingFPS: nil)
    }
}

enum ProcessingPurpose: Sendable, Equatable { case preview, export }

struct ProcessingPolicy: Sendable, Equatable {
    let purpose: ProcessingPurpose
    let computePolicy: DepthComputePolicy
    let depthMapMaxDimension: Int
    let depthInferencesPerSecond: Double
    let environmentChecksPerSecond: Double
    let useOpticalFlow: Bool
    let maximumConcurrentAnalysisTasks: Int

    func adapted(to runtime: RuntimeSystemState) -> Self {
        let cadence: Double
        let environmentCadence: Double
        switch runtime.thermalState {
        case .nominal: cadence = depthInferencesPerSecond; environmentCadence = environmentChecksPerSecond
        case .fair: cadence = max(2, depthInferencesPerSecond * 0.85); environmentCadence = max(0.75, environmentChecksPerSecond * 0.8)
        case .serious, .critical:
            cadence = max(2, depthInferencesPerSecond * 0.55)
            environmentCadence = max(0.5, environmentChecksPerSecond * 0.6)
        }
        return Self(purpose: purpose, computePolicy: computePolicy, depthMapMaxDimension: depthMapMaxDimension,
                    depthInferencesPerSecond: cadence, environmentChecksPerSecond: environmentCadence,
                    useOpticalFlow: false, maximumConcurrentAnalysisTasks: 1)
    }
}

struct ProcessingPolicyBuilder {
    func make(device: DeviceCapabilityProfile, source: VideoSourceProfile,
              runtime: RuntimeSystemState, purpose: ProcessingPurpose) -> ProcessingPolicy {
        let dimension: Int
        let cadence: Double
        switch (device.performanceClass, source.workload, purpose) {
        case (.high, .light, .export): dimension = 518; cadence = 5
        case (.high, .medium, .export), (.balanced, .light, .export): dimension = 384; cadence = 4
        case (_, .heavy, .export): dimension = 256; cadence = 2.5
        case (.conservative, _, .export): dimension = 256; cadence = 2
        case (_, _, .preview): dimension = source.workload == .heavy ? 256 : 320; cadence = 2
        default: dimension = 320; cadence = 3
        }
        let policy = ProcessingPolicy(purpose: purpose, computePolicy: device.preferredComputePolicy,
                                      depthMapMaxDimension: dimension, depthInferencesPerSecond: cadence,
                                      environmentChecksPerSecond: min(1.5, cadence / 2), useOpticalFlow: false,
                                      maximumConcurrentAnalysisTasks: 1)
        return policy.adapted(to: runtime)
    }
}
