import Foundation
import QuartzCore

/// Fake spectrum for the "simulated" soundwave mode: it looks like music
/// without listening to anything. Deterministic, allocation free per frame.
struct SimulatedSpectrum {
    /// Beats per minute of the imaginary track driving the low bands.
    private let tempo: Double = 118
    private let slowSpeeds: [Double] = [1.1, 1.7, 2.3, 3.1, 4.3, 5.7]
    private let fastSpeeds: [Double] = [3.7, 5.3, 7.1, 9.7, 12.3, 15.1]
    private let phases: [Double] = [0, 1.3, 2.7, 0.6, 3.4, 5.1]
    /// Highs carry less energy than lows in real music.
    private let weights: [Float] = [1, 0.97, 0.92, 0.88, 0.84, 0.8]

    func levels(at time: CFTimeInterval = CACurrentMediaTime()) -> [Float] {
        let beatPhase = (time * tempo / 60).truncatingRemainder(dividingBy: 1)
        let kick = pow(max(0, cos(beatPhase * 2 * .pi)), 6)          // on every beat
        let hat = pow(max(0, sin(beatPhase * 4 * .pi)), 10)          // between beats

        return (0..<SpectrumAnalyzer.bandCount).map { band in
            let slow = sin(time * slowSpeeds[band] + phases[band])
            let fast = sin(time * fastSpeeds[band] + phases[band] * 1.7)
            var value = 0.48 + 0.30 * slow + 0.20 * fast
            if band <= 1 { value = max(value, 0.3 + 0.65 * kick) }
            if band >= 4 { value = max(value, 0.25 + 0.6 * hat) }
            return min(max(Float(value) * weights[band], 0.04), 1)
        }
    }
}
