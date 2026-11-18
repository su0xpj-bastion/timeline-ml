import AVFoundation
import Foundation
import Speech

public struct Word: Codable, Equatable {
    public let text: String
    /// Seconds in the *source clip*.
    public let time: Double
    public let duration: Double
    public init(text: String, time: Double, duration: Double) { self.text = text; self.time = time; self.duration = duration }
}

public enum TranscriptError: Error { case notAuthorized, unavailable, failed(String) }

/// On-device speech-to-text with word timestamps (SFSpeechRecognizer, requiresOnDeviceRecognition).
public enum SpeechEngine {
    public static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Ask once; the system shows its permission dialog. Returns the resulting status.
    public static func requestAuthorization(timeout: Double = 120) -> SFSpeechRecognizerAuthorizationStatus {
        var status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        var done = false
        SFSpeechRecognizer.requestAuthorization { s in status = s; done = true }
        let end = Date().addingTimeInterval(timeout)
        while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return status
    }

    public struct Run {
        public let words: [Word]
        public let onDevice: Bool
        public let seconds: Double
    }

    public static func transcribe(_ clip: Clip, locale: String = "en-US") throws -> Run {
        guard authorized else { throw TranscriptError.notAuthorized }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)), rec.isAvailable else { throw TranscriptError.unavailable }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tml-\(UUID().uuidString).wav")
        try AudioIO.write(clip, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let req = SFSpeechURLRecognitionRequest(url: url)
        // Footage never leaves the device: refuse the server path rather than fall back to it.
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        var words: [Word] = [], error: Error?, done = false
        let t0 = Date()
        let task = rec.recognitionTask(with: req) { result, err in
            if let r = result, r.isFinal {
                words = r.bestTranscription.segments.flatMap { seg in splitSegment(seg.substring, time: seg.timestamp, duration: seg.duration) }
                done = true
            }
            if let e = err { error = e; done = true }
        }
        let end = Date().addingTimeInterval(120)
        while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        task.cancel()
        if let e = error, words.isEmpty { throw TranscriptError.failed("\(e)") }
        return Run(words: words, onDevice: req.requiresOnDeviceRecognition && rec.supportsOnDeviceRecognition, seconds: Date().timeIntervalSince(t0))
    }
}

/// A recognizer segment is not always one word: on-device recognition returned "village forgot
/// that" as a single segment. Split it, sharing the segment's time across words by length.
public func splitSegment(_ text: String, time: Double, duration: Double) -> [Word] {
    let parts = text.split(separator: " ").map(String.init)
    guard parts.count > 1, !Fault.on(.segmentsAssumedOneWord) else { return [Word(text: text, time: time, duration: duration)] }
    let total = Double(parts.reduce(0) { $0 + $1.count })
    var t = time
    return parts.map { p in
        let d = duration * Double(p.count) / total
        defer { t += d }
        return Word(text: p, time: t, duration: d)
    }
}

/// Transcript Search: find a word or phrase and land on it, in the clip or in an edited timeline.
public struct TranscriptIndex {
    public let words: [Word]
    public init(_ words: [Word]) { self.words = words }

    public static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }

    /// Source-clip times where the phrase starts.
    public func search(_ query: String) -> [Double] {
        let q = Self.normalize(query).split(separator: " ").map(String.init)
        guard !q.isEmpty else { return [] }
        let w = words.map { Self.normalize($0.text) }
        return w.indices.filter { i in i + q.count <= w.count && Array(w[i..<(i + q.count)]) == q }.map { words[$0].time }
    }

    /// The same search on an edited timeline: segments of the clip, in order. Hits outside every
    /// segment were cut, so they are not returned; the rest are timeline times.
    public func search(_ query: String, in edit: [(sourceIn: Double, sourceOut: Double)]) -> [Double] {
        var hits: [Double] = []
        for t in search(query) {
            var offset = 0.0
            for seg in edit {
                if t >= seg.sourceIn && t < seg.sourceOut {
                    hits.append(Fault.on(.transcriptSourceTimeOnTimeline) ? t : offset + (t - seg.sourceIn))
                }
                offset += seg.sourceOut - seg.sourceIn
            }
        }
        return hits.sorted()
    }

    /// Word error rate of `hyp` against `ref` (Levenshtein over normalized words).
    public static func wer(_ ref: String, _ hyp: String) -> Double {
        let r = normalize(ref).split(separator: " "), h = normalize(hyp).split(separator: " ")
        var d = Array(0...h.count)
        for i in 1...max(1, r.count) where !r.isEmpty {
            var prev = d[0]
            d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return r.isEmpty ? 0 : Double(d[h.count]) / Double(r.count)
    }
}
