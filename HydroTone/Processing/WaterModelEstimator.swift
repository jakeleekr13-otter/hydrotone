import CoreImage

struct WaterModelEstimator {
    func estimate(image: CIImage, depth: DepthEstimate, legacy: WaterAnalysis, context: CIContext) throws -> RestorationPlan {
        let map = depth.map
        let pixels = try pixels(from: image, width: map.width, height: map.height, context: context)
        let candidates = darkCandidates(pixels: pixels, depth: map.values)
        guard candidates.count >= 24 else { throw RestorationError.waterModelFitFailed }

        var infinity = SIMD3<Float>(repeating: 0)
        var betaBackscatter = SIMD3<Float>(repeating: 0)
        var fitQuality: Float = 0
        for channel in 0..<3 {
            let fit = fitBackscatter(channel: channel, candidates: candidates, pixels: pixels, depth: map.values)
            infinity[channel] = fit.infinity
            betaBackscatter[channel] = fit.beta
            fitQuality += fit.quality / 3
        }

        let fittedDirect = fitDirectAttenuation(pixels: pixels, depth: map.values,
                                                infinity: infinity, betaBackscatter: betaBackscatter)
        let priors = SIMD3<Float>(0.38 + legacy.redLoss * 0.9,
                                  0.20 + legacy.cyanDominance * 0.22,
                                  0.13 + legacy.cyanDominance * 0.10)
        var betaDirect = fittedDirect.value * 0.35 + priors * 0.65
        betaDirect = SIMD3(min(1.55, max(0.18, betaDirect.x)),
                           min(0.90, max(0.08, betaDirect.y)),
                           min(0.65, max(0.05, betaDirect.z)))
        // Channel-unequal attenuation needs a measured cast. A neutral scene gets equal
        // attenuation, so its greys stay grey; the spread grows with the cast.
        let cast = legacy.castStrength
        betaDirect = spread(betaDirect, by: cast)

        // darkCandidates keeps at most 256 per depth bin, so full coverage is 8 x 256 samples.
        let candidateCoverage = min(1, Float(candidates.count) / Float(8 * 256))
        let confidence = min(0.9, max(0, depth.confidence * sqrt(max(0, fitQuality))
                                     * (0.55 + 0.45 * candidateCoverage)
                                     * (0.7 + 0.3 * fittedDirect.quality)))
        guard confidence.isFinite else { throw RestorationError.waterModelFitFailed }

        // When red information is nearly absent, stronger amplification mostly reveals noise.
        let redSurvival = min(1, max(0, 1 - legacy.redLoss))
        let recoverability = channelRecoverability(pixels: pixels, depth: map.values, infinity: infinity,
                                                   betaBackscatter: betaBackscatter,
                                                   redSurvival: redSurvival)
        let limits = RestorationLimits(maximumGain: spread(SIMD3(1.32 + 0.45 * redSurvival, 1.55, 1.45), by: cast))
        let hits = limitHitPercentages(depth: map.values, betaDirect: betaDirect, limits: limits)
        return RestorationPlan(depth: map, depthSource: depth.source, depthStatistics: depth.statistics,
                               backscatterInfinity: finite(infinity), betaDirect: finite(betaDirect),
                               betaBackscatter: finite(betaBackscatter), confidence: confidence,
                               limits: limits, transmissionFloorPixelPercentage: hits.floor,
                               maximumGainPixelPercentage: hits.gain, depthConfidence: depth.confidence,
                               waterFitConfidence: sqrt(max(0, fitQuality)),
                               channelRecoverability: recoverability)
    }

    private func pixels(from image: CIImage, width: Int, height: Int, context: CIContext) throws -> [SIMD3<Float>] {
        let translated = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                                  y: CGFloat(height) / image.extent.height))
        var rgba = [Float](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &rgba, rowBytes: width * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
                       colorSpace: FilterEngine.workingSpace)
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(width * height)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let value = SIMD3(rgba[index], rgba[index + 1], rgba[index + 2])
            result.append(finite(value))
        }
        return result
    }

    private func darkCandidates(pixels: [SIMD3<Float>], depth: [Float]) -> [Int] {
        var selected: [Int] = []
        for bin in 0..<8 {
            let low = Float(bin) / 8, high = Float(bin + 1) / 8
            var indices = depth.indices.filter { depth[$0] >= low && (bin == 7 ? depth[$0] <= high : depth[$0] < high) }
            indices = indices.filter {
                let p = pixels[$0], luma = p.x * 0.2126 + p.y * 0.7152 + p.z * 0.0722
                return luma > 0.008 && luma < 0.82 && max(p.x, p.y, p.z) < 1
            }
            indices.sort {
                let a = pixels[$0], b = pixels[$1]
                return a.x + a.y + a.z < b.x + b.y + b.z
            }
            // A few hundred lower-envelope samples per bin are enough for the
            // three-parameter fit and keep preparation time independent of photo size.
            selected.append(contentsOf: indices.prefix(min(256, max(3, indices.count / 5))))
        }
        return selected
    }

    private func fitBackscatter(channel: Int, candidates: [Int], pixels: [SIMD3<Float>], depth: [Float])
        -> (infinity: Float, beta: Float, quality: Float) {
        var best = (infinity: Float(0.08), beta: Float(0.5), error: Float.greatestFiniteMagnitude)
        for step in 0...47 {
            let beta = 0.12 + Float(step) * 0.05
            var numerator: Float = 0, denominator: Float = 0
            for index in candidates {
                let factor = 1 - exp(-beta * depth[index])
                numerator += factor * pixels[index][channel]
                denominator += factor * factor
            }
            let infinity = min(0.9, max(0.005, numerator / max(denominator, 1e-6)))
            var errors: [Float] = []
            errors.reserveCapacity(candidates.count)
            for index in candidates {
                let prediction = infinity * (1 - exp(-beta * depth[index]))
                errors.append(abs(prediction - pixels[index][channel]))
            }
            errors.sort()
            let error = errors[errors.count / 2]
            if error < best.error { best = (infinity, beta, error) }
        }
        let quality = min(1, max(0, 1 - best.error / max(0.04, best.infinity)))
        return (best.infinity, best.beta, quality)
    }

    private func fitDirectAttenuation(pixels: [SIMD3<Float>], depth: [Float], infinity: SIMD3<Float>,
                                      betaBackscatter: SIMD3<Float>) -> (value: SIMD3<Float>, quality: Float) {
        var result = SIMD3<Float>(repeating: 0)
        var usableChannels: Float = 0
        for channel in 0..<3 {
            var points: [(Float, Float)] = []
            for bin in 0..<8 {
                let low = Float(bin) / 8, high = Float(bin + 1) / 8
                var values: [Float] = []
                for index in depth.indices where depth[index] >= low && (bin == 7 ? depth[index] <= high : depth[index] < high) {
                    let backscatter = infinity[channel] * (1 - exp(-betaBackscatter[channel] * depth[index]))
                    let direct = pixels[index][channel] - backscatter
                    if direct.isFinite && direct > 0.005 && direct < 1 { values.append(direct) }
                }
                guard values.count >= 8 else { continue }
                values.sort()
                let envelope = values[Int(Float(values.count - 1) * 0.8)]
                points.append(((low + high) / 2, log(max(1e-5, envelope))))
            }
            guard points.count >= 4 else { continue }
            let meanX = points.map(\.0).reduce(0, +) / Float(points.count)
            let meanY = points.map(\.1).reduce(0, +) / Float(points.count)
            let numerator = points.reduce(Float(0)) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            let denominator = points.reduce(Float(0)) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
            result[channel] = max(0, -numerator / max(denominator, 1e-6))
            usableChannels += 1
        }
        return (finite(result), usableChannels / 3)
    }

    private func limitHitPercentages(depth: [Float], betaDirect: SIMD3<Float>, limits: RestorationLimits)
        -> (floor: Float, gain: Float) {
        var floorHits = 0, gainHits = 0
        for z in depth {
            var pixelFloor = false, pixelGain = false
            for channel in 0..<3 {
                let transmission = exp(-betaDirect[channel] * z)
                pixelFloor = pixelFloor || transmission <= limits.transmissionFloor
                pixelGain = pixelGain || 1 / max(transmission, limits.transmissionFloor) >= limits.maximumGain[channel]
            }
            if pixelFloor { floorHits += 1 }
            if pixelGain { gainHits += 1 }
        }
        let count = Float(max(1, depth.count))
        return (Float(floorHits) * 100 / count, Float(gainHits) * 100 / count)
    }

    private func channelRecoverability(pixels: [SIMD3<Float>], depth: [Float], infinity: SIMD3<Float>,
                                       betaBackscatter: SIMD3<Float>, redSurvival: Float) -> SIMD3<Float> {
        var result = SIMD3<Float>(repeating: 0)
        for channel in 0..<3 {
            var direct: [Float] = []
            direct.reserveCapacity(min(4096, pixels.count))
            let stride = max(1, pixels.count / 4096)
            for index in Swift.stride(from: 0, to: pixels.count, by: stride) {
                let backscatter = infinity[channel] * (1 - exp(-betaBackscatter[channel] * depth[index]))
                let signal = pixels[index][channel] - backscatter
                if signal.isFinite && signal > 0 { direct.append(signal) }
            }
            direct.sort()
            let median = direct.isEmpty ? 0 : direct[direct.count / 2]
            result[channel] = min(1, max(0.08, (median - 0.004) / 0.075))
        }
        result.x = min(result.x, max(0.12, redSurvival))
        return finite(result)
    }

    /// Channel mean plus `amount` of each channel's difference from it.
    private func spread(_ value: SIMD3<Float>, by amount: Float) -> SIMD3<Float> {
        let mean = (value.x + value.y + value.z) / 3
        return SIMD3(repeating: mean) + (value - SIMD3(repeating: mean)) * min(1, max(0, amount))
    }

    private func finite(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value.x.isFinite ? value.x : 0, value.y.isFinite ? value.y : 0, value.z.isFinite ? value.z : 0)
    }
}
