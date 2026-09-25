import CoreImage
import os

struct RestorationFrameSignature: Sendable, Equatable {
    let luminanceHistogram: [Float]
    let meanChroma: SIMD2<Float>
    let depthMedian: Float
    let waterFitConfidence: Float
}

struct RestorationEnvironmentDetector: Sendable {
    private(set) var baseline: RestorationFrameSignature?
    private var candidatePersistence = 0

    mutating func observe(_ signature: RestorationFrameSignature) -> Bool {
        guard let baseline else { self.baseline = signature; return false }
        let histogramDistance = zip(baseline.luminanceHistogram, signature.luminanceHistogram)
            .reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / 2
        let chromaDelta = baseline.meanChroma - signature.meanChroma
        let chromaDistance = sqrt(chromaDelta.x * chromaDelta.x + chromaDelta.y * chromaDelta.y)
        let depthDistance = abs(baseline.depthMedian - signature.depthMedian)
        let fitChange = abs(baseline.waterFitConfidence - signature.waterFitConfidence)
        let evidence = [histogramDistance > 0.34, chromaDistance > 0.13,
                        depthDistance > 0.24, fitChange > 0.38].filter { $0 }.count
        if evidence >= 2 { candidatePersistence += 1 }
        else { candidatePersistence = max(0, candidatePersistence - 1) }
        if candidatePersistence >= 2 {
            self.baseline = signature
            candidatePersistence = 0
            return true
        }
        // Slowly follow ordinary camera movement without treating it as a new environment.
        if evidence == 0 { self.baseline = blend(baseline, signature, amount: 0.08) }
        return false
    }

    mutating func reset(to signature: RestorationFrameSignature? = nil) {
        baseline = signature
        candidatePersistence = 0
    }

    private func blend(_ a: RestorationFrameSignature, _ b: RestorationFrameSignature,
                       amount: Float) -> RestorationFrameSignature {
        RestorationFrameSignature(
            luminanceHistogram: zip(a.luminanceHistogram, b.luminanceHistogram).map { $0 + ($1 - $0) * amount },
            meanChroma: a.meanChroma + (b.meanChroma - a.meanChroma) * amount,
            depthMedian: a.depthMedian + (b.depthMedian - a.depthMedian) * amount,
            waterFitConfidence: a.waterFitConfidence + (b.waterFitConfidence - a.waterFitConfidence) * amount)
    }
}
