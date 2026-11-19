# Bugs and findings while building timeline-ml

Severity: S1 (data loss or privacy), S2 (wrong output), S3 (broken interaction), S4 (cosmetic).

### TL-1 · A loud kick drum makes the beat finder report half tempo
**S2 / P0** · found on the "loud pad 120" groove

- **Expected.** 120 BPM, F-measure ≥ 0.97.
- **Actual.** 60 BPM, F 0.66, with only every other beat found.
- **Isolation.** Autocorrelation of the onset envelope peaked at the kick's period (beats 1 and 3). The snares on 2 and 4 were weaker under the loud pad.
- **Fix.** Tempo strength also counts the half and double periods, under a perceptual prior around 120 BPM.
- **Guard.** `beats.hard-material`, and the fault `tempoOctaveError`, which fails 6 gates.

### TL-2 · A tempo change mid-song breaks tracking
**S2 / P1**

- **Actual.** F 0.62 over a 100 → 124 BPM change, because the tracker held one tempo for the whole song.
- **Fix.** Estimate tempo in 8 s windows, and track with a local period. F is now 0.98.

### TL-3 · Every beat is 4 ms early
**S2 / P1** · found from the signed error on the golden set

- **Isolation.** The same −4.0 ms appeared at every tempo and sample rate, so it was a detector offset (windows are timed by their centre), not noise.
- **Fix.** A measured 4 ms correction. Median error is now under 1 ms.

### TL-4 · Transcript search misses words the recognizer heard
**S2 / P0** · found by `transcript.search` on the first on-device run (9/12)

- **Steps.** `scripts/tml-app.sh transcript` dumps every word with its time.
- **Actual.** One entry read `13.05 +0.99 "village forgot that"`: three words in one segment.
- **Isolation.** The recognizer was right and the search was wrong. It assumed one word per `SFTranscriptionSegment`.
- **Fix.** Split segments into words, sharing the segment's time by length. Search is now 11/12.
- **Guard.** The `transcript.segments` gate (runs without permission, on CI too) and the fault `segmentsAssumedOneWord`.

### TL-5 · "sail" is always recognized as "sale"
**Finding (recognition limit)**

- **What happened.** A homophone in a clean synthesized voice, on-device en-US. The gate reports it rather than hiding it.

### TL-6 · The command-line tool crashes when it asks for speech permission
**S3 / P1** · SIGABRT, `namespace TCC`

- **Isolation.** The crash report said the app's Info.plist must contain `NSSpeechRecognitionUsageDescription`, even though the plist was embedded in the binary. A bare CLI inherits its launcher's privacy identity, and the launching app had no such key.
- **Fix.** `scripts/tml-app.sh` wraps the tool in a signed `TimelineML.app` and launches it with `open`.
- **Also found.** An ad-hoc signature changes on every build, and the permission is tied to it, so each rebuild asks again.

### TL-7 · A planted fault was never exercised inside XCTest
**Test-infrastructure** · found by CI (`synthRateAssumed48k` expected to fail `speech.sample-rate`, nothing failed)

- **Isolation.** The golden speech was cached by an earlier test before the fault was switched on.
- **Fix.** Caches are rebuilt for each fault.

### TL-8 · Half the cuts "missed" the beat frame at 25 fps
**Test design**

- **What happened.** At 120 BPM and 25 fps, every other beat falls exactly between two frames, so either frame is correct.
- **Fix.** The gate accepts the nearest frame within ±½ frame + 2 ms. The rounding fault (`snapFloorsToFrame`) is still caught.
