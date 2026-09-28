import Accelerate
import Foundation

/// Turns microphone audio into per-frequency-band levels (0...1) for the recorder waveform.
///
/// Owned by `CoreAudioRecorder` and called on the real-time audio thread, so every buffer is
/// allocated in `init` and `process` never allocates. Not thread-safe on its own.
final class SpectrumAnalyzer {
    static let bandCount = 8

    // Speech lives roughly between these; bands are log-spaced across them.
    private static let lowestFrequency: Float = 80
    private static let highestFrequency: Float = 8000

    // Band power (dB, per Hz) mapped onto 0...1. Calibrated against real dictation recordings:
    // room noise sits near 0 and normal speech peaks around 0.8–1.
    private static let floorDb: Float = -86
    private static let rangeDb: Float = 20
    // Speech energy falls off with frequency; lift higher bands so they stay visible.
    private static let tiltDbPerOctave: Float = 6

    // Bars jump up quickly and fall back smoothly, like a VU meter.
    private static let attackTime: Float = 0.015
    private static let releaseTime: Float = 0.14

    /// Input sample rate this analyzer was configured for.
    let sampleRate: Double
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let binWidth: Float

    private var window: [Float]
    private var ring: [Float]
    private var ringIndex = 0
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private let bandBins: [(start: Int, count: Int)]
    private let bandTiltDb: [Float]

    /// Smoothed level per band, lowest frequency first.
    private(set) var levels: [Float]

    init?(sampleRate: Double) {
        guard sampleRate > 0 else { return nil }
        self.sampleRate = sampleRate
        // ~40–60 ms window at common rates, enough resolution for the lowest band.
        fftSize = sampleRate > 24_000 ? 2048 : 1024
        log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        binWidth = Float(sampleRate) / Float(fftSize)

        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        ring = [Float](repeating: 0, count: fftSize)
        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2)
        levels = [Float](repeating: 0, count: Self.bandCount)

        let nyquist = Float(sampleRate) / 2
        let top = min(Self.highestFrequency, nyquist)
        let ratio = pow(top / Self.lowestFrequency, 1 / Float(Self.bandCount))
        var bins: [(start: Int, count: Int)] = []
        var tilts: [Float] = []
        for band in 0..<Self.bandCount {
            let low = Self.lowestFrequency * pow(ratio, Float(band))
            let high = low * ratio
            let lastBin = fftSize / 2 - 1
            var start = Int((low / binWidth).rounded(.up))
            var end = Int((high / binWidth).rounded(.down))
            start = min(max(start, 1), lastBin)
            end = min(max(end, start), lastBin)
            bins.append((start, end - start + 1))
            let center = sqrt(low * high)
            tilts.append(Self.tiltDbPerOctave * log2(center / 1000))
        }
        bandBins = bins
        bandTiltDb = tilts
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Feeds interleaved Float32 samples and updates `levels`.
    func process(_ samples: UnsafePointer<Float32>, frameCount: Int, channelCount: Int) {
        guard frameCount > 0, channelCount > 0 else { return }

        let channelScale = 1 / Float(channelCount)
        ring.withUnsafeMutableBufferPointer { ring in
            for index in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += samples[index * channelCount + channel]
                }
                ring[ringIndex] = sum * channelScale
                ringIndex = (ringIndex + 1) % fftSize
            }
        }

        computePowerSpectrum()
        updateLevels(elapsed: Float(Double(frameCount) / sampleRate))
    }

    private func computePowerSpectrum() {
        let n = fftSize
        let half = n / 2

        // Unroll the ring buffer oldest → newest, then window it.
        ring.withUnsafeBufferPointer { ring in
            frame.withUnsafeMutableBufferPointer { frame in
                let tail = n - ringIndex
                frame.baseAddress!.update(from: ring.baseAddress! + ringIndex, count: tail)
                (frame.baseAddress! + tail).update(from: ring.baseAddress!, count: ringIndex)
            }
        }
        frame.withUnsafeMutableBufferPointer { frame in
            vDSP_vmul(frame.baseAddress!, 1, window, 1, frame.baseAddress!, 1, vDSP_Length(n))
        }

        real.withUnsafeMutableBufferPointer { realp in
            imag.withUnsafeMutableBufferPointer { imagp in
                var split = DSPSplitComplex(realp: realp.baseAddress!, imagp: imagp.baseAddress!)
                frame.withUnsafeBufferPointer { frame in
                    frame.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip packs the Nyquist term into imagp[0]; the DC bin is never used.
                imagp[0] = 0
                power.withUnsafeMutableBufferPointer { power in
                    vDSP_zvmags(&split, 1, power.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Scale so a full-scale sine reads 1.0 (0 dB): zrip doubles the DFT and Hann halves it.
        var scale = 4 / Float(n * n)
        power.withUnsafeMutableBufferPointer { power in
            vDSP_vsmul(power.baseAddress!, 1, &scale, power.baseAddress!, 1, vDSP_Length(half))
        }
    }

    private func updateLevels(elapsed: Float) {
        let attack = exp(-elapsed / Self.attackTime)
        let release = exp(-elapsed / Self.releaseTime)

        power.withUnsafeBufferPointer { power in
            levels.withUnsafeMutableBufferPointer { levels in
                for band in 0..<Self.bandCount {
                    let bins = bandBins[band]
                    var sum: Float = 0
                    for bin in bins.start..<(bins.start + bins.count) {
                        sum += power[bin]
                    }
                    // Per-Hz density keeps levels comparable across sample rates and FFT sizes.
                    let density = sum / Float(bins.count) / binWidth
                    let db = 10 * log10(density + 1e-20) + bandTiltDb[band]
                    let target = min(max((db - Self.floorDb) / Self.rangeDb, 0), 1)

                    let current = levels[band]
                    let coefficient = target > current ? attack : release
                    levels[band] = target + (current - target) * coefficient
                }
            }
        }
    }
}
