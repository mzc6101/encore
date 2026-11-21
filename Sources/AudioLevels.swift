import SwiftUI
import CoreAudio
import Accelerate

/// Live 5-band level meter driven by a Core Audio process tap (system output mix).
/// Only band magnitudes are computed; audio is never stored or written anywhere.
@MainActor final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()

    @Published private(set) var bands: [Float] = Array(repeating: 0, count: 5)
    @Published private(set) var isLive = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var analyzer: BandAnalyzer?
    private let queue = DispatchQueue(label: "encore.audiolevels", qos: .userInteractive)

    func start() {
        if let fake = ProcessInfo.processInfo.environment["ENCORE_DEBUG_FAKEAUDIO"], fakeTimer == nil {
            // Debug: drive the bars with random levels to measure rendering cost without the capture prompt.
            isLive = true
            fakeTimer = Timer.scheduledTimer(withTimeInterval: Double(fake) ?? 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.bands = (0..<5).map { _ in Float.random(in: 0.1...1) } }
            }
            return
        }
        guard ioProc == nil, tapID == kAudioObjectUnknown else { return }
        guard setUp() else { teardown(); isLive = false; return }
        isLive = true
    }

    private var fakeTimer: Timer?

    func stop() {
        fakeTimer?.invalidate(); fakeTimer = nil
        teardown()
        isLive = false
        if bands.contains(where: { $0 != 0 }) { bands = Array(repeating: 0, count: 5) }
    }

    private func setUp() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Encore level tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); return false }

        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &uidRef) == noErr, let tapUID = uidRef?.takeRetainedValue() as String? else { return false }

        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Encore Levels",
            kAudioAggregateDeviceUIDKey: "encore.levels.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        if let out = defaultOutputUID() {
            agg[kAudioAggregateDeviceMainSubDeviceKey] = out
            agg[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: out]]
        }
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID) == noErr else { aggregateID = AudioObjectID(kAudioObjectUnknown); return false }

        let analyzer = BandAnalyzer(sampleRate: nominalRate(aggregateID)) { [weak self] b in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.bands = b } }
        }
        self.analyzer = analyzer
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue, { _, input, _, _, _ in
            analyzer.process(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        }) == noErr, ioProc != nil else { ioProc = nil; return false }
        return AudioDeviceStart(aggregateID, ioProc) == noErr
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let p = ioProc { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        analyzer?.onBands = nil
        analyzer = nil
    }

    private func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func nominalRate(_ dev: AudioObjectID) -> Double {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate) == noErr && rate > 8000 ? rate : 48000
    }
}

/// Runs on the audio queue. Mono mixdown -> 1024-pt Hann FFT -> 5 log-spaced bands (60 Hz-12 kHz) -> dB 0...1.
private final class BandAnalyzer: @unchecked Sendable {
    static let n = 1024
    static let bandCount = 5
    var onBands: (([Float]) -> Void)?

    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private let window: [Float]
    private var ring = [Float](repeating: 0, count: BandAnalyzer.n)
    private var head = 0
    private var frame = [Float](repeating: 0, count: BandAnalyzer.n)
    private var real = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var imag = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var power = [Float](repeating: 0, count: BandAnalyzer.n / 2)
    private var smoothed = [Float](repeating: 0, count: BandAnalyzer.bandCount)
    private var lastPublish: UInt64 = 0
    // 10 updates a second: each update redraws the glass card (~4% CPU at 10 Hz vs ~6% at 15 Hz).
    private let minInterval: UInt64 = 100_000_000
    private let ranges: [(Int, Int)]
    // Music spectra fall ~with frequency; tilt so the upper bands move too.
    private let tilt: [Float] = [0, 3, 7, 11, 15]

    init(sampleRate: Double, onBands: @escaping ([Float]) -> Void) {
        self.onBands = onBands
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: BandAnalyzer.n, isHalfWindow: false)
        let binWidth = sampleRate / Double(BandAnalyzer.n)
        let ratio = pow(12000.0 / 60.0, 1.0 / Double(BandAnalyzer.bandCount))
        ranges = (0..<BandAnalyzer.bandCount).map { i in
            let lo = max(1, Int((60.0 * pow(ratio, Double(i)) / binWidth).rounded()))
            let hi = min(BandAnalyzer.n / 2 - 1, max(lo + 1, Int((60.0 * pow(ratio, Double(i + 1)) / binWidth).rounded())))
            return (lo, hi)
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ list: UnsafeMutableAudioBufferListPointer) {
        let n = BandAnalyzer.n
        guard let first = list.first else { return }
        // Mono mixdown straight into the ring buffer (handles interleaved and planar layouts).
        if list.count > 1 {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<frames {
                var s: Float = 0, c: Float = 0
                for b in list { if let p = b.mData?.assumingMemoryBound(to: Float.self), i < Int(b.mDataByteSize) / 4 { s += p[i]; c += 1 } }
                push(c > 0 ? s / c : 0)
            }
        } else if let p = first.mData?.assumingMemoryBound(to: Float.self) {
            let ch = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p[i * ch + c] }
                push(s / Float(ch))
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastPublish >= minInterval else { return }
        lastPublish = now

        for i in 0..<n { frame[i] = ring[(head + i) % n] }
        vDSP.multiply(frame, window, result: &frame)
        frame.withUnsafeBufferPointer { fp in
            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    power.withUnsafeMutableBufferPointer { vDSP_zvmags(&split, 1, $0.baseAddress!, 1, vDSP_Length(n / 2)) }
                } }
            }
        }
        // zrip output is scaled by 2 and the Hann window has 0.5 mean gain: normalise to ~full-scale = 0 dB.
        let norm: Float = 1 / Float(n * n)
        for (i, (lo, hi)) in ranges.enumerated() {
            var peak: Float = 0
            for k in lo...hi { peak = max(peak, power[k]) }
            let db = 10 * log10f(peak * norm + 1e-12) + tilt[i]
            let target = min(1, max(0, (db + 75) / 50))
            let delta = target - smoothed[i]
            smoothed[i] += delta * (delta > 0 ? 0.7 : 0.18)
        }
        onBands?(smoothed)
    }

    @inline(__always) private func push(_ s: Float) {
        ring[head] = s
        head = (head + 1) % BandAnalyzer.n
    }
}

struct WaveformBars: View {
    @ObservedObject var levels: AudioLevels
    let isPlaying: Bool

    init(levels: AudioLevels, isPlaying: Bool) {
        self.levels = levels
        self.isPlaying = isPlaying
    }

    var body: some View {
        if levels.isLive && isPlaying {
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.7))
                        .frame(width: 2.4, height: max(2.4, 14 * CGFloat(levels.bands[i])))
                }
            }
            .frame(width: 18, height: 14)
            // No interpolation: each level update draws once instead of animating the glass at 60 fps.
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.7))
                // Static on purpose: any running animation inside the glass card redraws the glass every frame.
                .frame(width: 18, height: 14)
        }
    }
}
