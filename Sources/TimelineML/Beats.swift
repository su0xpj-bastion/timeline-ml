import Accelerate
import Foundation

/// Beat detection for "snap edits to the music": onset strength (spectral flux), a tempo estimate
/// (onset autocorrelation with a perceptual prior), dynamic-programming beat tracking (Ellis 2007),
/// then each beat refined to its onset. Accelerate/vDSP only; runs on any Apple platform.
public enum BeatTracker {
    public static let frame = 1024
    public static let hop = 128

    public struct Result {
        public let beats: [Double]
        public let bpm: Double
    }

    /// Seconds for a sample index. Getting the rate wrong is the bug `assumes48k` stands for.
    static func seconds(_ index: Double, _ c: Clip) -> Double { index / (Fault.on(.assumes48k) ? 48000 : c.rate) }

    /// Spectral flux: positive change of log-magnitude per bin, summed. One value per hop.
    public static func onsetEnvelope(_ c: Clip) -> [Float] {
        let n = frame, log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let frames = max(0, (c.samples.count - n) / hop)
        var prev = [Float](repeating: 0, count: n / 2)
        var env = [Float](repeating: 0, count: frames)
        var buf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mag = [Float](repeating: 0, count: n / 2)
        for f in 0..<frames {
            c.samples.withUnsafeBufferPointer { src in vDSP_vmul(src.baseAddress! + f * hop, 1, window, 1, &buf, 1, vDSP_Length(n)) }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    buf.withUnsafeBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
                }
            }
            var flux: Float = 0
            for k in 1..<(n / 2) {
                let m = log1p(100 * mag[k])
                let d = m - prev[k]
                if d > 0 { flux += d }
                prev[k] = m
            }
            env[f] = flux
        }
        // Remove the slow trend (pads, swells) with a 1 s moving average, keep the positive part.
        let w = Int(c.rate / Double(hop))
        var out = env
        var acc: Float = 0
        for i in env.indices {
            acc += env[i]
            if i >= w { acc -= env[i - w] }
            out[i] = max(0, env[i] - acc / Float(min(i + 1, w)))
        }
        let peak = out.max() ?? 1
        return out.map { $0 / max(peak, 1e-9) }
    }

    /// Frames per second of the onset envelope.
    static func envRate(_ c: Clip) -> Double { (Fault.on(.assumes48k) ? 48000 : c.rate) / Double(hop) }

    /// Tempo from autocorrelation over 60-200 BPM. The log-normal prior centred on 120 BPM is what
    /// keeps an 8th-note hi-hat pattern from being heard at double tempo.
    static func autocorr(_ env: ArraySlice<Float>, lag: Double) -> Double {
        let n = env.count, l0 = Int(lag), frac = Float(lag - Double(l0)), b = env.startIndex
        guard l0 + 1 < n else { return 0 }
        var s: Float = 0
        for i in 0..<(n - l0 - 1) { s += env[b + i] * (env[b + i + l0] * (1 - frac) + env[b + i + l0 + 1] * frac) }
        return Double(s) / Double(n - l0)
    }

    /// Tempo strength also counts the half and double periods, so a pulse that is metrically
    /// consistent (kick on 1 and 3, snare on 2 and 4) beats one loud drum heard at half tempo.
    public static func tempo(_ env: ArraySlice<Float>, envRate: Double, around center: Double = 120) -> Double {
        var best = 0.0, bestBPM = center
        for bpm10 in stride(from: 600, through: 2000, by: 2) {
            let bpm = Double(bpm10) / 10
            let lag = envRate * 60 / bpm
            var strength = autocorr(env, lag: lag)
            if !Fault.on(.tempoOctaveError) { strength += 0.5 * autocorr(env, lag: 2 * lag) + 0.5 * autocorr(env, lag: lag / 2) }
            let prior = Fault.on(.tempoOctaveError) ? 1 : exp(-0.5 * pow(log2(bpm / center) / 0.9, 2))
            let score = strength * prior
            if score > best { best = score; bestBPM = bpm }
        }
        return bestBPM
    }

    public static func tempo(_ env: [Float], envRate: Double) -> Double { tempo(env[...], envRate: envRate) }

    /// Local beat period per envelope frame: tempo in 8 s windows every 2 s, centred on the global
    /// tempo so a window cannot jump an octave. Lets the tracker follow a tempo change.
    static func periods(_ env: [Float], envRate: Double, global: Double) -> [Double] {
        let win = Int(8 * envRate), step = Int(2 * envRate), n = env.count
        guard n > win else { return [Double](repeating: envRate * 60 / global, count: n) }
        var centers: [(Int, Double)] = []
        var s = 0
        while s + win <= n {
            let bpm = tempo(env[s..<(s + win)], envRate: envRate, around: global)
            centers.append((s + win / 2, envRate * 60 / bpm))
            s += step
        }
        return (0..<n).map { t in
            guard let j = centers.firstIndex(where: { $0.0 >= t }) else { return centers.last!.1 }
            if j == 0 { return centers[0].1 }
            let (t0, p0) = centers[j - 1], (t1, p1) = centers[j]
            return p0 + (p1 - p0) * Double(t - t0) / Double(t1 - t0)
        }
    }

    public static func track(_ c: Clip) -> Result {
        let env = onsetEnvelope(c)
        let er = envRate(c)
        let bpm = tempo(env, envRate: er)
        let local = periods(env, envRate: er, global: bpm)
        // Dynamic programming: each beat rewards onset strength and penalises deviation from the local period.
        let n = env.count, alpha = 40.0
        var score = env.map { Double($0) }, back = [Int](repeating: -1, count: n)
        for t in 0..<n {
            let period = local[t]
            let lo = max(0, t - Int(2 * period)), hi = t - Int(period / 2)
            guard hi > lo else { continue }
            var best = -Double.infinity, arg = -1
            for tau in lo..<hi {
                let v = score[tau] - alpha * pow(log(Double(t - tau) / period), 2)
                if v > best { best = v; arg = tau }
            }
            if arg >= 0 { score[t] += best; back[t] = arg }
        }
        let tail = max(0, n - Int(local.last ?? 1))
        var t = (tail..<n).max { score[$0] < score[$1] } ?? 0
        var frames: [Int] = []
        while t >= 0 { frames.append(t); t = back[t] }
        frames.reverse()
        // Refine to the onset: strongest envelope value within ±25 ms, parabolic peak.
        let r = Int(0.025 * er)
        let beats: [Double] = frames.map { f in
            let lo = max(1, f - r), hi = min(n - 2, f + r)
            guard hi > lo else { return Double(f) }
            let p = (lo...hi).max { env[$0] < env[$1] }!
            let a = Double(env[p - 1]), b = Double(env[p]), cc = Double(env[p + 1])
            let d = a - 2 * b + cc
            return Double(p) + (d != 0 ? 0.5 * (a - cc) / d : 0)
        }.map { f in seconds(f * Double(hop) + Double(frame) / 2 - latency * c.rate, c) }
        // Reported tempo: median of the inter-beat intervals actually tracked.
        let ibis = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        return Result(beats: beats, bpm: ibis.isEmpty ? bpm : 60 / ibis[ibis.count / 2])
    }

    /// Fixed detector offset, measured on the golden set: the half-frame centre puts flux peaks
    /// 4 ms before the transient's first sample, so beats are moved 4 ms later.
    public static var latency = -0.004
}

/// MIREX-style beat evaluation: a detection within ±70 ms of a true beat is a hit.
public enum BeatEval {
    public struct Score { public let f: Double; public let medianError: Double; public let p95Error: Double; public let hits: Int }

    public static func score(_ detected: [Double], truth: [Double], window: Double = 0.07, skipFirst: Double = 1.0) -> Score {
        let truth = truth.filter { $0 >= skipFirst }, det = detected.filter { $0 >= skipFirst - window }
        var used = Set<Int>(), errs: [Double] = []
        for t in truth {
            var bestJ = -1, bestE = Double.infinity
            for (j, d) in det.enumerated() where !used.contains(j) && Swift.abs(d - t) < Swift.abs(bestE) {
                bestJ = j
                bestE = d - t
            }
            if bestJ >= 0 && Swift.abs(bestE) <= window {
                used.insert(bestJ)
                errs.append(bestE)
            }
        }
        let p = det.isEmpty ? 0 : Double(errs.count) / Double(det.count), r = truth.isEmpty ? 0 : Double(errs.count) / Double(truth.count)
        let f = p + r == 0 ? 0 : 2 * p * r / (p + r)
        let abs = errs.map { Swift.abs($0) }.sorted()
        return Score(f: f, medianError: abs.isEmpty ? 1 : abs[abs.count / 2], p95Error: abs.isEmpty ? 1 : abs[min(abs.count - 1, abs.count * 95 / 100)],
                     hits: errs.count)
    }
}
