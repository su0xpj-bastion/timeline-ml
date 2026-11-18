import AVFoundation
import Foundation

public struct Rng {
    var s: UInt64
    public init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    public mutating func next() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000 }
    public mutating func noise() -> Float { Float(next() * 2 - 1) }
}

/// Music and speech with known answers, synthesized from seeds (no downloads, no licensing).
public enum Golden {
    // MARK: drums

    public struct Groove {
        public var tempo: [(beat: Int, bpm: Double)]   // tempo map: from `beat` on, this tempo
        public var beats: Int
        public var swing: Double                       // 0.5 = straight 8ths, 0.66 = triplet swing
        public var bed: Float                          // level of the sustained pad + noise bed
        public var rate: Double
        public var seed: UInt64
        public init(bpm: Double, beats: Int = 64, swing: Double = 0.5, bed: Float = 0.08, rate: Double = 48000, seed: UInt64 = 1,
                    tempo: [(beat: Int, bpm: Double)]? = nil) {
            self.tempo = tempo ?? [(0, bpm)]; self.beats = beats; self.swing = swing; self.bed = bed; self.rate = rate; self.seed = seed
        }

        /// Ground-truth beat times (quarter notes), integrating the tempo map.
        public var beatTimes: [Double] {
            var t = 0.0, out: [Double] = []
            for b in 0..<beats {
                out.append(t)
                let bpm = tempo.last { $0.beat <= b }!.bpm
                t += 60 / bpm
            }
            return out
        }
    }

    /// Kick on 1 and 3, snare on 2 and 4, hats on (swung) 8ths, over a pad and a noise bed.
    public static func drums(_ g: Groove) -> Clip {
        let beats = g.beatTimes
        let end = (beats.last ?? 0) + 60 / g.tempo.last!.bpm + 0.5
        var x = [Float](repeating: 0, count: Int(end * g.rate))
        var r = Rng(g.seed)
        func add(_ at: Double, _ f: (Double) -> Float, length: Double) {
            let s0 = Int(at * g.rate)
            for i in 0..<Int(length * g.rate) where s0 + i < x.count { x[s0 + i] += f(Double(i) / g.rate) }
        }
        for (i, t) in beats.enumerated() {
            let ibi = i + 1 < beats.count ? beats[i + 1] - t : 60 / g.tempo.last!.bpm
            if i % 2 == 0 {   // kick: falling sine sweep, 120 Hz -> 50 Hz
                add(t, { s in
                    let phase: Double = 2 * Double.pi * (50 * s + 70 * (1 - exp(-s * 30)) / 30)
                    let amp: Double = 0.9 * exp(-s * 18)
                    return Float(amp * sin(phase))
                }, length: 0.25)
            } else {          // snare: noise burst + body tone
                var rr = Rng(g.seed &+ UInt64(i))
                add(t, { s in
                    let env = Float(exp(-s * 25))
                    let tone = Float(sin(2 * Double.pi * 185 * s))
                    return env * (0.5 * rr.noise() + 0.3 * tone)
                }, length: 0.2)
            }
            for (k, frac) in [0.0, g.swing].enumerated() {   // hats on 8ths
                var rr = Rng(g.seed &+ UInt64(1000 + i * 2 + k))
                var prev: Float = 0
                add(t + frac * ibi, { s in
                    let n = rr.noise()
                    let hp = n - prev        // crude high-pass
                    prev = n
                    return Float(0.12 * exp(-s * 90)) * hp
                }, length: 0.05)
            }
        }
        // Pad (A minor, slow attack) + low noise: musical texture without onsets.
        for i in 0..<x.count {
            let s = Double(i) / g.rate
            let env = Float(min(1, s / 2))
            let w = 2 * Double.pi * s
            let chord: Double = sin(w * 220) + 0.7 * sin(w * 261.6) + 0.6 * sin(w * 329.6)
            let pad = Float(chord / 2.3)
            x[i] += g.bed * env * (pad + 0.4 * r.noise())
        }
        return Clip(x, rate: g.rate)
    }

    // MARK: speech

    public static let lines = [
        "Chapter two, the coast at dawn.",
        "We filmed the lighthouse for three days.",
        "The keeper told us about the storm.",
        "Her boat came back without a sail.",
        "Nobody in the village forgot that night.",
        "This is where the story really begins.",
    ]

    public struct Spoken {
        public let clip: Clip
        /// Ground truth per line: start and end time in the clip (seconds) and its words.
        public let spans: [(start: Double, end: Double, text: String)]
    }

    /// Lines spoken by the system voice (22.05 kHz), resampled to 48 kHz, separated by known silences.
    public static func speech(rate: Double = 48000, gap: Double = 0.9) -> Spoken {
        var out = [Float](repeating: 0, count: Int(0.5 * rate))
        var spans: [(Double, Double, String)] = []
        for line in lines {
            let raw = synthesize(line)
            // The voice is 22.05 kHz; a pipeline that assumes 48 kHz plays it 2.2x fast and mistimes everything.
            let at48 = Fault.on(.synthRateAssumed48k) ? Clip(raw.samples, rate: rate) : AudioIO.resample(raw, to: rate)
            let start = Double(out.count) / rate
            out += at48.samples
            spans.append((start, Double(out.count) / rate, line))
            out += [Float](repeating: 0, count: Int(gap * rate))
        }
        return Spoken(clip: Clip(out, rate: rate), spans: spans)
    }

    public static func synthesize(_ text: String) -> Clip {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.45
        var samples: [Float] = [], rate = 22050.0, finished = false
        synth.write(u) { buf in
            guard let pcm = buf as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finished = true; return }
            rate = pcm.format.sampleRate
            samples += Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        }
        // The synthesizer delivers buffers on the main run loop.
        let end = Date().addingTimeInterval(30)
        while !finished && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        // Trim leading/trailing silence so the span is the speech itself.
        let thr: Float = 0.01
        let first = samples.firstIndex { abs($0) > thr } ?? 0
        let last = samples.lastIndex { abs($0) > thr } ?? max(0, samples.count - 1)
        return Clip(Array(samples[first...last]), rate: rate)
    }
}
