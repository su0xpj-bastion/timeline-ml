import TimelineML
import XCTest

/// One XCTest per gate. Speech gates skip (XCTSkip) where on-device recognition is not authorized,
/// which includes every headless CI runner; run `tml authorize` once on a dev Mac or Jenkins agent.
final class GateTests: XCTestCase {
    func gate(_ name: String) throws {
        let r = Gates.run([name]).first!
        if r.status == .skip { throw XCTSkip(r.detail) }
        XCTAssertEqual(r.status, .pass, "\(name): \(r.detail)")
    }

    func test_beats_accuracy() throws { try gate("beats.accuracy") }
    func test_beats_tempo() throws { try gate("beats.tempo") }
    func test_beats_hard_material() throws { try gate("beats.hard-material") }
    func test_beats_aac_roundtrip() throws { try gate("beats.aac-roundtrip") }
    func test_beats_sample_rates() throws { try gate("beats.sample-rates") }
    func test_snap_to_beat() throws { try gate("snap.to-beat") }
    func test_timecode_rates() throws { try gate("timecode.rates") }
    func test_speech_sample_rate() throws { try gate("speech.sample-rate") }
    func test_transcript_timeline_mapping() throws { try gate("transcript.timeline-mapping") }
    func test_transcript_segments() throws { try gate("transcript.segments") }
    func test_transcript_accuracy() throws { try gate("transcript.accuracy") }
    func test_transcript_search() throws { try gate("transcript.search") }
    func test_transcript_on_device() throws { try gate("transcript.on-device") }
    func test_perf_budgets() throws { try gate("perf.budgets") }
}

final class FaultMatrixTests: XCTestCase {
    func testEveryFaultIsCaughtByExactlyItsGates() {
        for fault in Fault.allCases {
            let saved = Fault.active
            Fault.active = [fault]
            Gates.resetCaches()
            defer { Fault.active = saved; Gates.resetCaches() }
            let failed = Set(Gates.run().filter { $0.status == .fail && $0.name != "perf.budgets" }.map { $0.name })
            XCTAssertEqual(failed, Gates.expectedFailures[fault], "\(fault)")
        }
    }
}

final class UnitTests: XCTestCase {
    func testWER() {
        XCTAssertEqual(TranscriptIndex.wer("the coast at dawn", "the coast at dawn"), 0)
        XCTAssertEqual(TranscriptIndex.wer("the coast at dawn", "the coast dawn"), 0.25)
        XCTAssertEqual(TranscriptIndex.wer("a b", "a b c d"), 1)
    }

    func testSearchIsCaseAndPunctuationBlind() {
        let idx = TranscriptIndex([Word(text: "Three", time: 1, duration: 0.2), Word(text: "days.", time: 1.3, duration: 0.2)])
        XCTAssertEqual(idx.search("three DAYS"), [1])
    }

    func testBeatTrackingCost() {
        let c = Golden.drums(Golden.Groove(bpm: 120, beats: 32, seed: 3))
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) { _ = BeatTracker.track(c) }
    }
}
