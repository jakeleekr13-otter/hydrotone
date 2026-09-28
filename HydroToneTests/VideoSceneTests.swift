import XCTest
@testable import HydroTone

final class VideoSceneTests: XCTestCase {
    private func sample(_ r: Float, _ g: Float, _ b: Float) -> WaterAnalysis {
        WaterAnalysis(meanRed: r, meanGreen: g, meanBlue: b)
    }

    func testSteadyClipIsOneScene() {
        let samples = (0..<20).map { i in sample(0.085 + 0.002 * Float(i % 3), 0.195 + 0.004 * Float(i % 4), 0.36 + 0.006 * Float(i % 5)) }
        XCTAssertEqual(VideoSceneSplitter.sceneStarts(samples), [0])
    }

    func testOneOddKeyframeDoesNotStartAScene() {
        let water = sample(0.085, 0.195, 0.36), dark = sample(0.04, 0.09, 0.19)
        XCTAssertEqual(VideoSceneSplitter.sceneStarts([water, water, water, dark, water, water]), [0])
    }

    func testLastOddKeyframeDoesNotStartAScene() {
        let water = sample(0.085, 0.195, 0.36), dark = sample(0.04, 0.09, 0.19)
        XCTAssertEqual(VideoSceneSplitter.sceneStarts([water, water, water, dark]), [0])
    }

    func testPersistentChangeStartsASceneAtItsFirstKeyframe() {
        let water = sample(0.085, 0.195, 0.36), dark = sample(0.04, 0.09, 0.19)
        XCTAssertEqual(VideoSceneSplitter.sceneStarts([water, water, water, dark, dark, dark]), [0, 3])
    }

    func testEmptyAndNonFiniteSamples() {
        XCTAssertEqual(VideoSceneSplitter.sceneStarts([]), [])
        let bad = sample(.nan, 0.2, 0.3)
        XCTAssertEqual(VideoSceneSplitter.sceneStarts([bad, bad, bad]), [0])
    }

    /// Keyframe mean colours (one per second) that WaterAnalysis logged for a real 42 s dive clip on
    /// 28 Sep 2026: steady water until 20 s, the sunlit surface from 21 s, a turn to deep water at 36 s.
    func testRealDiveClipSplitsAtItsSceneChanges() {
        let means: [(Float, Float, Float)] = [
            (0.08094, 0.18558, 0.34761), (0.09186, 0.21172, 0.38561), (0.08890, 0.20461, 0.37565),
            (0.08584, 0.19729, 0.36504), (0.08512, 0.19549, 0.36305), (0.08704, 0.20007, 0.36972),
            (0.09263, 0.21351, 0.38885), (0.08163, 0.18705, 0.35150), (0.08229, 0.18861, 0.35395),
            (0.08261, 0.18937, 0.35519), (0.08273, 0.18964, 0.35591), (0.08454, 0.19390, 0.36262),
            (0.08491, 0.19481, 0.36374), (0.08799, 0.20222, 0.37414), (0.08734, 0.20075, 0.37125),
            (0.08698, 0.20000, 0.36908), (0.08682, 0.19973, 0.36758), (0.08483, 0.19506, 0.35990),
            (0.08318, 0.19126, 0.35291), (0.08817, 0.20323, 0.37011), (0.09572, 0.22140, 0.39575),
            (0.11060, 0.25760, 0.44277), (0.11533, 0.26939, 0.45548), (0.11701, 0.27390, 0.45748),
            (0.11533, 0.27017, 0.44906), (0.11641, 0.27351, 0.44674), (0.12056, 0.28423, 0.45488),
            (0.12468, 0.29515, 0.46079), (0.12782, 0.30353, 0.46475), (0.12882, 0.30781, 0.45314),
            (0.12670, 0.30357, 0.43886), (0.13110, 0.31488, 0.44794), (0.13262, 0.31949, 0.44550),
            (0.13806, 0.33362, 0.45311), (0.12668, 0.30596, 0.41714), (0.13856, 0.33323, 0.44181),
            (0.08770, 0.21065, 0.29951), (0.04689, 0.10824, 0.19565), (0.04073, 0.09177, 0.18801),
            (0.04603, 0.10326, 0.21603), (0.06482, 0.14787, 0.28437), (0.06947, 0.15970, 0.29501)]
        let starts = VideoSceneSplitter.sceneStarts(means.map { sample($0.0, $0.1, $0.2) })
        XCTAssertEqual(starts, [0, 21, 36, 37, 40])
    }

    func testKeyframeTimes() throws {
        let clip = VideoRestorationAnalyzer.keyframeTimes(duration: 41.8)
        XCTAssertEqual(clip.count, 42)
        XCTAssertEqual(clip.first, 0)
        XCTAssertEqual(try XCTUnwrap(clip.last), 41.7, accuracy: 1e-9)
        XCTAssertEqual(clip[1] - clip[0], 41.7 / 41, accuracy: 1e-9)

        XCTAssertEqual(VideoRestorationAnalyzer.keyframeTimes(duration: 3).count, 10, "Short clips keep 10 keyframes")
        let hour = VideoRestorationAnalyzer.keyframeTimes(duration: 3600)
        XCTAssertEqual(hour.count, 120, "Long clips are capped")
        XCTAssertEqual(hour[1] - hour[0], 3599.9 / 119, accuracy: 1e-9)
        XCTAssertEqual(VideoRestorationAnalyzer.keyframeTimes(duration: 0), [0])
        XCTAssertEqual(VideoRestorationAnalyzer.keyframeTimes(duration: 0.05), [0])
    }

    func testFitsSpreadEvenlyOverAScene() {
        let spread = VideoRestorationAnalyzer.spread(0..<22, count: 10)
        XCTAssertEqual(spread.count, 10)
        XCTAssertEqual(spread.first, 0)
        XCTAssertEqual(spread.last, 21)
        XCTAssertEqual(spread, spread.sorted())
        XCTAssertEqual(Set(spread).count, 10)
        XCTAssertEqual(VideoRestorationAnalyzer.spread(5..<8, count: 10), [5, 6, 7])
        XCTAssertEqual(VideoRestorationAnalyzer.spread(4..<5, count: 10), [4])
    }

    func testColorCorrectionMixCoversEveryStoredValue() {
        XCTAssertEqual(Mirror(reflecting: ColorCorrection()).children.count,
                       ColorCorrection.mixedScalars.count + ColorCorrection.mixedVectors.count,
                       "A new ColorCorrection value must be added to mixedScalars or mixedVectors")
        var a = ColorCorrection(), b = ColorCorrection()
        for (i, key) in ColorCorrection.mixedScalars.enumerated() { a[keyPath: key] = Float(i); b[keyPath: key] = Float(i) + 2 }
        for key in ColorCorrection.mixedVectors { a[keyPath: key] = .init(repeating: 1); b[keyPath: key] = .init(repeating: 3) }
        XCTAssertEqual(a.mixed(with: b, amount: 0), a)
        XCTAssertEqual(a.mixed(with: b, amount: 1), b)
        let half = a.mixed(with: b, amount: 0.5)
        for (i, key) in ColorCorrection.mixedScalars.enumerated() { XCTAssertEqual(half[keyPath: key], Float(i) + 1, accuracy: 1e-6) }
        for key in ColorCorrection.mixedVectors { XCTAssertEqual(half[keyPath: key], .init(repeating: 2)) }
    }
}
