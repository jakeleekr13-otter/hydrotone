import XCTest
import CoreImage
@testable import HydroTone

final class RestorationTests: XCTestCase {
    private let parameters = (
        infinity: SIMD3<Float>(0.08, 0.18, 0.32),
        betaDirect: SIMD3<Float>(0.9, 0.45, 0.25),
        betaBackscatter: SIMD3<Float>(0.55, 0.42, 0.31)
    )

    func testImageFormationForwardInverseConsistency() {
        let clear = SIMD3<Float>(0.24, 0.52, 0.68)
        let observed = RestorationMath.forward(clear: clear, depth: 0.55,
            backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
            betaBackscatter: parameters.betaBackscatter)
        let limits = RestorationLimits(transmissionFloor: 0.01, maximumGain: .init(repeating: 10),
                                       highlightStart: 10, highlightEnd: 11, maximumOutput: 4)
        let restored = RestorationMath.inverse(observed: observed, depth: 0.55,
            backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
            betaBackscatter: parameters.betaBackscatter, limits: limits)
        assertEqual(restored.color, clear, accuracy: 0.0001)
        XCTAssertFalse(restored.hitTransmissionFloor)
        XCTAssertFalse(restored.hitMaximumGain)
    }

    func testZeroAndNearZeroDepthRemainStable() {
        let source = SIMD3<Float>(0.2, 0.4, 0.7)
        for depth: Float in [0, 0.000001] {
            let restored = RestorationMath.inverse(observed: source, depth: depth,
                backscatterInfinity: parameters.infinity, betaDirect: parameters.betaDirect,
                betaBackscatter: parameters.betaBackscatter, limits: .init())
            assertEqual(restored.color, source, accuracy: 0.00001)
        }
    }

    func testExtremeAttenuationUsesTransmissionFloorAndStaysFinite() {
        let limits = RestorationLimits(transmissionFloor: 0.3, maximumGain: .init(repeating: 10),
                                       highlightStart: 10, highlightEnd: 11, maximumOutput: 2)
        let result = RestorationMath.inverse(observed: .init(repeating: 0.2), depth: 1,
            backscatterInfinity: .zero, betaDirect: .init(repeating: 20),
            betaBackscatter: .init(repeating: 3), limits: limits)
        XCTAssertTrue(result.hitTransmissionFloor)
        XCTAssertTrue(result.color.x.isFinite && result.color.y.isFinite && result.color.z.isFinite)
        XCTAssertEqual(result.color.x, 0.2 / 0.3, accuracy: 0.0001)
    }

    func testMaximumChannelGainIsEnforced() {
        let limits = RestorationLimits(transmissionFloor: 0.01, maximumGain: .init(1.2, 1.3, 1.4),
                                       highlightStart: 10, highlightEnd: 11, maximumOutput: 2)
        let result = RestorationMath.inverse(observed: .init(repeating: 0.1), depth: 1,
            backscatterInfinity: .zero, betaDirect: .init(repeating: 5),
            betaBackscatter: .init(repeating: 1), limits: limits)
        XCTAssertTrue(result.hitMaximumGain)
        XCTAssertEqual(result.color.x, 0.12, accuracy: 0.0001)
        XCTAssertEqual(result.color.y, 0.13, accuracy: 0.0001)
        XCTAssertEqual(result.color.z, 0.14, accuracy: 0.0001)
    }

    func testNaNAndInfinityAreSanitized() {
        let result = RestorationMath.inverse(observed: .init(.nan, .infinity, 0.2), depth: .nan,
            backscatterInfinity: .init(.nan, 0.2, .infinity), betaDirect: .init(.infinity, .nan, 0.2),
            betaBackscatter: .init(.nan, .infinity, 0.2), limits: .init())
        XCTAssertTrue(result.color.x.isFinite && result.color.y.isFinite && result.color.z.isFinite)
        XCTAssertGreaterThanOrEqual(result.color.min(), 0)
    }

    func testConfidenceFallbackAndDeterminism() {
        let current = SIMD3<Float>(0.1, 0.3, 0.6), restored = SIMD3<Float>(0.7, 0.5, 0.2)
        XCTAssertEqual(RestorationMath.confidenceBlend(current: current, restored: restored, confidence: 0), current)
        XCTAssertEqual(RestorationMath.confidenceBlend(current: current, restored: restored, confidence: .nan), current)
        let first = RestorationMath.confidenceBlend(current: current, restored: restored, confidence: 0.35)
        let second = RestorationMath.confidenceBlend(current: current, restored: restored, confidence: 0.35)
        XCTAssertEqual(first, second)
    }

    func testBundledDepthModelProducesCompactFiniteDepth() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Depth Anything's compressed MPSGraph backend requires a physical Apple device")
        #else
        let foreground = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.08))
            .cropped(to: CGRect(x: 70, y: 45, width: 180, height: 130))
        let background = CIImage(color: CIColor(red: 0.05, green: 0.42, blue: 0.65))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 220))
        let image = foreground.composited(over: background)
        let estimate = try await DepthEstimator().monocularDepth(for: image)
        XCTAssertEqual(estimate.map.width, 518)
        XCTAssertEqual(estimate.map.height, 392)
        XCTAssertEqual(estimate.map.values.count, 518 * 392)
        XCTAssertTrue(estimate.map.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertNotNil(estimate.inferenceMilliseconds)
        print("Depth Anything physical inference: \(estimate.inferenceMilliseconds ?? -1) ms")
        #endif
    }

    private func assertEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 { XCTAssertEqual(lhs[channel], rhs[channel], accuracy: accuracy, file: file, line: line) }
    }
}
