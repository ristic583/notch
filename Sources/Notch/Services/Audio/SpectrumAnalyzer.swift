import Accelerate
import os

/// Real-time safe FFT → a few logarithmic bands, each normalized to 0...1.
/// `process` runs on the audio thread, `currentLevels` on the main thread.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = 6
    /// Band edges in Hz (log spaced, roughly equal octave widths).
    static let bandEdges: [Float] = [60, 150, 400, 1000, 2500, 6000, 14000]
    /// Small high-frequency lift: music energy falls off with frequency.
    static let bandTilt: [Float] = [0, 0, 1, 2, 3.5, 5]

    // Normalization. Each bar = (how loud the band is relative to the loudest band
    // recently) × (how much it jumps above its own recent average). The first keeps
    // real differences between bands, the second makes each bar move on its own,
    // so dense, compressed masters don't turn into a row of equal bars.
    /// Window below the loudest band that maps to 0...1.
    static let relativeRangeDB: Float = 40
    /// The loudness reference never drops below this, so quiet noise isn't amplified.
    static let minimumReferenceDB: Float = -42
    /// Bands below this are treated as silence.
    static let gateDB: Float = -68
    /// How fast the reference falls after loud parts (dB per second).
    static let referenceReleaseDBPerSecond: Float = 5
    /// Time constant of each band's running average.
    static let averageTime: Float = 0.35
    /// dB above/below the band average that maps to full/no punch.
    static let punchRangeDB: Float = 3
    /// Share of the bar driven by punch (the rest is steady loudness). 1 = fully punch-driven.
    static let punchWeight: Float = 1

    private let fftSize = 2048
    private let hopSize = 1024
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    private var window: [Float]
    private var ring: [Float]
    private var ringIndex = 0
    private var samplesSinceFFT = 0
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var bandBins: [Range<Int>] = []
    private var sampleRate: Double = 0
    private var hopDuration: Float = 0
    private var referenceDB: Float = SpectrumAnalyzer.minimumReferenceDB
    private var averageDB = [Float](repeating: -90, count: SpectrumAnalyzer.bandCount)
    private var bandDB = [Float](repeating: -90, count: SpectrumAnalyzer.bandCount)

    private let output = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
    private var scratchLevels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        ring = [Float](repeating: 0, count: fftSize)
        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Must be called before `process`, off the audio thread.
    func configure(sampleRate: Double) {
        guard sampleRate != self.sampleRate, sampleRate > 0 else { return }
        self.sampleRate = sampleRate
        hopDuration = Float(hopSize) / Float(sampleRate)
        let binWidth = Float(sampleRate) / Float(fftSize)
        let maxBin = fftSize / 2 - 1
        bandBins = (0..<Self.bandCount).map { band in
            let lo = max(1, Int((Self.bandEdges[band] / binWidth).rounded(.down)))
            let hi = min(maxBin, max(lo + 1, Int((Self.bandEdges[band + 1] / binWidth).rounded(.up))))
            return lo..<hi
        }
        reset()
    }

    func reset() {
        for i in ring.indices { ring[i] = 0 }
        ringIndex = 0
        samplesSinceFFT = 0
        referenceDB = Self.minimumReferenceDB
        for i in averageDB.indices { averageDB[i] = -90 }
        output.withLock { levels in
            for i in levels.indices { levels[i] = 0 }
        }
    }

    /// Feed mono samples. Allocation free.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        guard !bandBins.isEmpty else { return }
        var offset = 0
        while offset < count {
            let chunk = min(count - offset, fftSize - ringIndex)
            ring.withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + ringIndex).update(from: samples + offset, count: chunk)
            }
            ringIndex = (ringIndex + chunk) % fftSize
            samplesSinceFFT += chunk
            offset += chunk
            if samplesSinceFFT >= hopSize {
                samplesSinceFFT = 0
                analyze()
            }
        }
    }

    /// Latest band levels (0...1). Main thread.
    func currentLevels() -> [Float] {
        output.withLock { $0 }
    }

    private func analyze() {
        let n = fftSize
        let half = n / 2
        // Unroll the ring (oldest sample first) and apply the window.
        ring.withUnsafeBufferPointer { src in
            frame.withUnsafeMutableBufferPointer { dst in
                let tail = n - ringIndex
                dst.baseAddress!.update(from: src.baseAddress! + ringIndex, count: tail)
                (dst.baseAddress! + tail).update(from: src.baseAddress!, count: ringIndex)
            }
        }
        frame.withUnsafeMutableBufferPointer { f in
            vDSP_vmul(f.baseAddress!, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
        }

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                frame.withUnsafeBufferPointer { framePtr in
                    framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }

        // zrip output is 2x the DFT; Hann spreads a sine over ~1.5 bins of energy.
        // This scaling makes a band's value ≈ its RMS power relative to full scale.
        let scale = 1 / (Float(half) * Float(half) * 3)
        var loudest: Float = -120
        power.withUnsafeBufferPointer { p in
            for band in 0..<Self.bandCount {
                let bins = bandBins[band]
                var sum: Float = 0
                vDSP_sve(p.baseAddress! + bins.lowerBound, 1, &sum, vDSP_Length(bins.count))
                let db = 10 * log10f(sum * scale + 1e-12) + Self.bandTilt[band]
                bandDB[band] = db
                loudest = max(loudest, db)
            }
        }

        // Reference follows the loudest band up quickly and falls slowly.
        if loudest > referenceDB {
            referenceDB += (loudest - referenceDB) * 0.5
        } else {
            referenceDB -= Self.referenceReleaseDBPerSecond * hopDuration
        }
        referenceDB = max(referenceDB, Self.minimumReferenceDB)

        let averaging = 1 - expf(-hopDuration / Self.averageTime)
        for band in 0..<Self.bandCount {
            let db = bandDB[band]
            guard db > Self.gateDB else {
                averageDB[band] += (db - averageDB[band]) * averaging
                scratchLevels[band] = 0
                continue
            }
            let loudness = min(max((db - (referenceDB - Self.relativeRangeDB)) / Self.relativeRangeDB, 0), 1)
            let punch = min(max(0.5 + (db - averageDB[band]) / (2 * Self.punchRangeDB), 0), 1)
            averageDB[band] += (db - averageDB[band]) * averaging
            let level = powf(loudness, 1.6) * ((1 - Self.punchWeight) + Self.punchWeight * punch * 2)
            scratchLevels[band] = min(level, 1)
        }
        _ = output.withLockIfAvailable { levels in
            for i in 0..<Self.bandCount { levels[i] = scratchLevels[i] }
        }
    }
}
