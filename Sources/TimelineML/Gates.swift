import Foundation

public struct GateResult: Codable {
    public enum Status: String, Codable { case pass, fail, skip }
    public let name: String
    public let status: Status
    public let detail: String
    public let metrics: [String: Double]
}

public struct Gate {
    public let name: String
    /// True when the gate needs on-device speech recognition (and so the user's permission).
    public let needsSpeech: Bool
    public let run: () throws -> GateResult
}

public enum Gates {
    static func r(_ n: String, _ ok: Bool, _ d: String, _ m: [String: Double] = [:]) -> GateResult {
        GateResult(name: n, status: ok ? .pass : .fail, detail: d, metrics: m)
    }
    static func ms(_ x: Double) -> String { String(format: "%.1f ms", x * 1000) }

    // Budgets.
    public static let beatF = 0.97            // MIREX F-measure, ±70 ms
    public static let beatMedian = 0.005      // 5 ms
    public static let beatP95 = 0.015         // 15 ms: half a frame at 30 fps
    public static let tempoBPM = 0.5

    static let straight: [Golden.Groove] = [90.0, 100, 120, 128, 140].map { Golden.Groove(bpm: $0, seed: UInt64($0)) }
    static let hard: [(String, Golden.Groove)] = [
        ("swing 110", Golden.Groove(bpm: 110, swing: 0.66, bed: 0.15, seed: 7)),
        ("loud pad 120", Golden.Groove(bpm: 120, bed: 0.3, seed: 8)),
        ("tempo 100->124", Golden.Groove(bpm: 100, beats: 64, seed: 9, tempo: [(0, 100), (32, 124)])),
    ]
    static let scratch: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-ml")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static var spokenCache: Golden.Spoken?
    static var spoken: Golden.Spoken {
        if let s = spokenCache { return s }
        let s = Golden.speech()
        spokenCache = s
        return s
    }
    static var transcriptCache: SpeechEngine.Run?
    static func transcript() throws -> SpeechEngine.Run {
        if let t = transcriptCache { return t }
        let t = try SpeechEngine.transcribe(spoken.clip)
        transcriptCache = t
        return t
    }

    /// Search targets: (query, index of the line it is in).
    static let queries: [(String, Int)] = [
        ("coast", 0), ("dawn", 0), ("lighthouse", 1), ("three days", 1), ("keeper", 2), ("storm", 2),
        ("boat", 3), ("sail", 3), ("village", 4), ("that night", 4), ("story", 5), ("begins", 5),
    ]

    public static let all: [Gate] = [
        // MARK: beats
        Gate(name: "beats.accuracy", needsSpeech: false) {
            var worstF = 1.0, worstMed = 0.0, worstP95 = 0.0
            for g in straight {
                let s = BeatEval.score(BeatTracker.track(Golden.drums(g)).beats, truth: g.beatTimes)
                worstF = min(worstF, s.f); worstMed = max(worstMed, s.medianError); worstP95 = max(worstP95, s.p95Error)
            }
            return r("beats.accuracy", worstF >= beatF && worstMed <= beatMedian && worstP95 <= beatP95,
                     String(format: "90-140 BPM: worst F %.3f, median %@, p95 %@", worstF, ms(worstMed), ms(worstP95)),
                     ["worst_f": worstF, "median_error_s": worstMed, "p95_error_s": worstP95])
        },
        Gate(name: "beats.tempo", needsSpeech: false) {
            var worst = 0.0, detail: [String] = []
            for g in straight {
                let got = BeatTracker.track(Golden.drums(g)).bpm
                worst = max(worst, abs(got - g.tempo[0].bpm))
                detail.append(String(format: "%.0f→%.1f", g.tempo[0].bpm, got))
            }
            return r("beats.tempo", worst <= tempoBPM, "tempo error ≤ \(String(format: "%.2f", worst)) BPM (\(detail.joined(separator: ", ")))",
                     ["tempo_error_bpm": worst])
        },
        Gate(name: "beats.hard-material", needsSpeech: false) {
            var rows: [String] = [], worst = 1.0
            for (name, g) in hard {
                let s = BeatEval.score(BeatTracker.track(Golden.drums(g)).beats, truth: g.beatTimes)
                worst = min(worst, s.f)
                rows.append(String(format: "%@ F %.3f", name, s.f))
            }
            return r("beats.hard-material", worst >= 0.95, rows.joined(separator: ", "), ["worst_f": worst])
        },
        Gate(name: "beats.aac-roundtrip", needsSpeech: false) {
            // Export to AAC and read back: priming must not move a single beat.
            let g = Golden.Groove(bpm: 128, seed: 11)
            let url = scratch.appendingPathComponent("aac-128.m4a")
            try AudioIO.write(Golden.drums(g), to: url, aac: true)
            let back = try AudioIO.read(url)
            let s = BeatEval.score(BeatTracker.track(back).beats, truth: g.beatTimes)
            let signed = BeatTracker.track(back).beats.filter { $0 > 1 }
            let truthAfter = g.beatTimes.filter { $0 > 1 }
            let bias = zip(signed, truthAfter).map { $0 - $1 }.sorted()
            let median = bias.isEmpty ? 1 : bias[bias.count / 2]
            return r("beats.aac-roundtrip", s.f >= beatF && abs(median) <= beatMedian,
                     String(format: "AAC 192k: F %.3f, median offset %+.1f ms", s.f, median * 1000), ["aac_offset_s": median])
        },
        Gate(name: "beats.sample-rates", needsSpeech: false) {
            var worst = 0.0
            for rate in [44100.0, 48000, 96000] {
                let g = Golden.Groove(bpm: 120, rate: rate, seed: 10)
                let s = BeatEval.score(BeatTracker.track(Golden.drums(g)).beats, truth: g.beatTimes)
                worst = max(worst, s.f >= beatF ? s.medianError : 1)
            }
            return r("beats.sample-rates", worst <= beatMedian, "44.1 / 48 / 96 kHz: worst median error \(ms(worst))", ["rate_error_s": worst])
        },

        // MARK: snapping + timecode
        Gate(name: "snap.to-beat", needsSpeech: false) {
            // An editor drags cuts near the beat; each must land on the true beat's frame.
            let g = Golden.Groove(bpm: 120, seed: 12)
            let beats = BeatTracker.track(Golden.drums(g)).beats
            // "On the beat" = the frame nearest the true beat. When a beat falls exactly between two
            // frames (120 BPM at 25 fps does, every other beat) either frame is right: allow half a
            // frame plus 2 ms.
            var ok = 0, total = 0, worst = 0.0
            var rng = Rng(5)
            for rate in [FrameRate.fps23_976, .fps25, .fps29_97DF] {
                for t in g.beatTimes where t > 1 {
                    let cut = t + (rng.next() - 0.5) * 0.2
                    let err = abs(Double(Snap.cut(cut, beats: beats, rate)) / rate.exact - t)
                    total += 1
                    if err <= 0.5 / rate.exact + 0.002 { ok += 1 }
                    worst = max(worst, err * rate.exact)
                }
            }
            let rate = Double(ok) / Double(total)
            return r("snap.to-beat", rate >= 0.98, String(format: "%d/%d cuts on the beat's nearest frame (23.976, 25, 29.97 DF), worst %.2f frames", ok, total, worst),
                     ["on_beat_rate": rate])
        },
        Gate(name: "timecode.rates", needsSpeech: false) {
            let cases: [(FrameRate, Int, String)] = [
                (.fps29_97DF, 1800, "00:01:00;02"), (.fps29_97DF, 17982, "00:10:00;00"), (.fps29_97DF, 107892, "01:00:00;00"),
                (.fps59_94DF, 215784, "01:00:00;00"), (.fps59_94DF, 3600, "00:01:00;04"),
                (.fps23_976, 86400, "01:00:00:00"), (.fps25, 90000, "01:00:00:00"), (.fps30, 108000, "01:00:00:00"),
            ]
            let wrong = cases.filter { Timecode.string(frame: $0.1, $0.0) != $0.2 }
            return r("timecode.rates", wrong.isEmpty,
                     wrong.isEmpty ? "\(cases.count)/\(cases.count) reference timecodes" :
                        wrong.map { "\($0.0.rawValue) f\($0.1): \(Timecode.string(frame: $0.1, $0.0)) ≠ \($0.2)" }.joined(separator: "; "))
        },

        // MARK: speech
        Gate(name: "speech.sample-rate", needsSpeech: false) {
            // The voice renders at 22.05 kHz; each line's length must survive the move to 48 kHz.
            let raw = Golden.synthesize(Golden.lines[1])
            let span = spoken.spans[1]
            let want = raw.duration, got = span.end - span.start
            return r("speech.sample-rate", abs(got - want) <= 0.002,
                     String(format: "line 2: %.3f s at %.0f Hz → %.3f s at 48 kHz", want, raw.rate, got), ["duration_error_s": abs(got - want)])
        },
        Gate(name: "transcript.timeline-mapping", needsSpeech: false) {
            // Search in an edited timeline: lines 3, 1, 5 in that order; line 2 was cut.
            let sp = spoken
            let words = sp.spans.enumerated().flatMap { i, s -> [Word] in
                let ws = s.text.split(separator: " ")
                return ws.enumerated().map { j, w in Word(text: String(w), time: s.start + (s.end - s.start) * Double(j) / Double(ws.count), duration: 0.2) }
            }
            let index = TranscriptIndex(words)
            let edit = [2, 0, 4].map { (sourceIn: sp.spans[$0].start - 0.2, sourceOut: sp.spans[$0].end + 0.2) }
            let lens = edit.map { $0.sourceOut - $0.sourceIn }
            var problems: [String] = []
            // "coast" is in line 1 = second segment: timeline time = first segment length + offset in line 1.
            let coast = index.search("coast", in: edit), coastSrc = index.search("coast")[0]
            let want = lens[0] + (coastSrc - edit[1].sourceIn)
            if coast.count != 1 || abs(coast[0] - want) > 1e-6 { problems.append("coast at \(coast) want \(want)") }
            if !index.search("lighthouse", in: edit).isEmpty { problems.append("found a word from the cut line") }
            // "village" is in line 5 = third segment: after the first two segments.
            let village = index.search("village", in: edit)
            if village.count != 1 || village[0] < lens[0] + lens[1] { problems.append("village at \(village)") }
            if !index.search("story", in: edit).isEmpty { problems.append("found a word from a line not in the edit") }
            return r("transcript.timeline-mapping", problems.isEmpty, problems.isEmpty ? "hits land in timeline time; cut lines are not found" : problems.joined(separator: "; "))
        },
        Gate(name: "transcript.segments", needsSpeech: false) {
            // Recorded from a real on-device run: one segment held three words.
            let words = splitSegment("village forgot that", time: 13.05, duration: 0.99)
            let idx = TranscriptIndex(words + [Word(text: "night", time: 14.04, duration: 0.45)])
            let v = idx.search("village"), n = idx.search("that night")
            let ok = v == [13.05] && n.count == 1 && n[0] > 13.05 && n[0] < 14.04
            return r("transcript.segments", ok, ok ? "a 3-word segment is searchable word by word" : "village \(v), that night \(n)")
        },
        Gate(name: "transcript.accuracy", needsSpeech: true) {
            let t = try transcript()
            let hyp = t.words.map { $0.text }.joined(separator: " ")
            let wer = TranscriptIndex.wer(Golden.lines.joined(separator: " "), hyp)
            return r("transcript.accuracy", wer <= 0.1, String(format: "WER %.1f%% on %d lines (budget 10%%)", wer * 100, Golden.lines.count),
                     ["wer": wer])
        },
        Gate(name: "transcript.search", needsSpeech: true) {
            let t = try transcript()
            let index = TranscriptIndex(t.words)
            var found = 0, misses: [String] = []
            for (q, line) in queries {
                let span = spoken.spans[line]
                if index.search(q).contains(where: { $0 >= span.start - 0.15 && $0 <= span.end }) { found += 1 } else { misses.append(q) }
            }
            let rate = Double(found) / Double(queries.count)
            return r("transcript.search", rate >= 0.9, "\(found)/\(queries.count) queries land inside their spoken line \(misses)", ["hit_rate": rate])
        },
        Gate(name: "transcript.on-device", needsSpeech: true) {
            let t = try transcript()
            let rtf = t.seconds / spoken.clip.duration
            return r("transcript.on-device", t.onDevice, String(format: "on-device only: %@, %.2fx real time", t.onDevice ? "yes" : "NO", rtf),
                     ["realtime_factor": rtf])
        },

        // MARK: cost
        Gate(name: "perf.budgets", needsSpeech: false) {
            let c = Golden.drums(Golden.Groove(bpm: 120, seed: 1))
            _ = BeatTracker.track(c)
            let t0 = Date()
            _ = BeatTracker.track(c)
            let s = Date().timeIntervalSince(t0)
            let speed = c.duration / s
            return r("perf.budgets", speed >= 20, String(format: "beat tracking %.0fx real time (budget 20x)", speed), ["beat_speed_x": speed])
        },
    ]

    public static var names: [String] { all.map { $0.name } }

    /// Golden speech and transcripts are cached per run; a fault that changes how they are made
    /// (e.g. synthRateAssumed48k) needs them rebuilt.
    public static func resetCaches() { spokenCache = nil; transcriptCache = nil }

    public static func run(_ names: [String] = []) -> [GateResult] {
        all.filter { names.isEmpty || names.contains($0.name) }.map { g in
            if g.needsSpeech && !SpeechEngine.authorized {
                return GateResult(name: g.name, status: .skip, detail: "skipped: on-device speech recognition not authorized on this machine", metrics: [:])
            }
            do { return try g.run() } catch {
                return GateResult(name: g.name, status: .fail, detail: "error: \(error)", metrics: [:])
            }
        }
    }

    /// Fault -> gates that must fail (speech gates excluded: they skip where recognition is not authorized).
    public static let expectedFailures: [Fault: Set<String>] = [
        .aacPrimingCompensatedTwice: ["beats.aac-roundtrip"],
        .assumes48k: ["beats.sample-rates"],
        // A wrong tempo spoils everything downstream of the beat grid.
        .tempoOctaveError: ["beats.accuracy", "beats.tempo", "beats.hard-material", "beats.aac-roundtrip", "beats.sample-rates", "snap.to-beat"],
        .snapFloorsToFrame: ["snap.to-beat"],
        .dropFrameIgnored: ["timecode.rates"],
        .transcriptSourceTimeOnTimeline: ["transcript.timeline-mapping"],
        .synthRateAssumed48k: ["speech.sample-rate"],
        .segmentsAssumedOneWord: ["transcript.segments"],
    ]
}
