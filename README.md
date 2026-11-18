# timeline-ml

Quality gates for the two editing features that tie a video timeline to its sound, the kind
Final Cut Pro lists as **Beat Detection** and **Transcript Search**. Each feature is checked
against a golden set with exact answers, and against a fault matrix of the integration bugs
that move a cut by a frame or land a search hit in the wrong place.

| Gate | What it holds |
|---|---|
| `beats.accuracy` | 90–140 BPM: F-measure ≥ 0.97 (±70 ms), median error ≤ 5 ms, p95 ≤ 15 ms |
| `beats.tempo` | tempo within ±0.5 BPM |
| `beats.hard-material` | swung 8ths, a loud pad, a tempo change mid-song: F ≥ 0.95 |
| `beats.aac-roundtrip` | export to AAC, read back: median offset ≤ 5 ms (encoder priming handled once) |
| `beats.sample-rates` | 44.1 / 48 / 96 kHz give the same beats |
| `snap.to-beat` | cuts dragged near a beat land on the beat's nearest frame at 23.976, 25, 29.97 DF |
| `timecode.rates` | reference timecodes at 23.976, 25, 30, 29.97 DF, 59.94 DF |
| `speech.sample-rate` | 22.05 kHz synthesized speech keeps its length at 48 kHz |
| `transcript.timeline-mapping` | search in an edited timeline returns timeline time; words from cut lines are not found |
| `transcript.segments` | a recognizer segment holding several words is searchable word by word |
| `transcript.accuracy` | on-device recognition: word error rate ≤ 10% |
| `transcript.search` | ≥ 90% of queries land inside the line they were spoken in |
| `transcript.on-device` | recognition runs with `requiresOnDeviceRecognition` (footage never leaves the device) |
| `perf.budgets` | beat tracking ≥ 20× real time |

**Beat Detection.** There is no public Apple API for it, so `BeatTracker` is built here on
Accelerate/vDSP:
- spectral-flux onsets
- tempo from onset autocorrelation, with half/double-period harmonics and a perceptual prior
- local tempo in 8 s windows
- dynamic-programming beat tracking (Ellis 2007)
- each beat refined to its onset with parabolic interpolation

**Transcript Search** uses the Speech framework on-device (`SFSpeechRecognizer`, word timestamps).

**Golden set.** Everything is synthesized from seeds:
- Drum grooves with a kick, snare, swung hi-hats, a pad and a noise bed, at known tempos, with a tempo change.
- Interview lines spoken by the system voice (`AVSpeechSynthesizer`), placed at known times.

## Fault matrix

`TML_FAULTS=<name>` switches on one integration bug. Each must fail exactly these gates
(`tools/fault_matrix.py`, and `FaultMatrixTests`):

| Fault | Caught by |
|---|---|
| aacPrimingCompensatedTwice (app trims 2112 priming samples the decoder already removed) | beats.aac-roundtrip |
| assumes48k (sample index → seconds at 48 kHz for every file) | beats.sample-rates |
| tempoOctaveError (no tempo prior: the kick on 1 and 3 is heard at half tempo) | beats.accuracy, beats.tempo, beats.hard-material, beats.aac-roundtrip, beats.sample-rates, snap.to-beat |
| snapFloorsToFrame (truncate instead of round) | snap.to-beat |
| dropFrameIgnored (29.97 counted as 30 non-drop) | timecode.rates |
| transcriptSourceTimeOnTimeline (search hits in clip time on an edited timeline) | transcript.timeline-mapping |
| synthRateAssumed48k (22.05 kHz speech used as 48 kHz) | speech.sample-rate |
| segmentsAssumedOneWord (one recognizer segment = one word) | transcript.segments |

## Measured locally

macOS 26, Apple silicon, Command Line Tools only.

- **Beat accuracy:** F-measure ≥ 0.976 at every tempo. Median error is 0.5–1.9 ms and p95 ≤ 2.8 ms, at 44.1, 48 and 96 kHz and through AAC.
- **Tempo:** within 0.18 BPM.
- **Speed:** beat tracking runs about 80× faster than real time.

Findings while calibrating:
- The raw tracker locked onto a loud kick at half tempo (60 instead of 120 BPM). Counting the half and double periods in tempo strength fixed it.
- A fixed-tempo tracker scored F 0.62 across a 100 → 124 BPM change. Local tempo in 8 s windows raised it to F 0.98.
- The flux detector puts beats a constant 4 ms early, because windows are timed by their centre. That offset is measured on the golden set and corrected.
- At 120 BPM and 25 fps, every other beat falls exactly between two frames. "On the beat" therefore means the nearest frame, ±½ frame.
- The system voice renders at 22.05 kHz. Treating it as 48 kHz would shrink every line to 46% of its length.
- **On-device recognition** (all 14 gates, with permission): word error rate 7.3%, at 0.06× real time, on-device only.
  - **Multi-word segment.** It returned "village forgot that" as one segment. Search that assumed one word per segment could find neither "village" nor "that night" (9/12 hits). Splitting segments by length raised that to 11/12. The old assumption is pinned as a fault.
  - **Homophone.** "sail" is heard as "sale" every time. This is a real recognition miss on a homophone, and the gate reports it rather than hiding it.
  - **"two".** "Chapter two" comes back as "Chapter 2".

## Speech permission: why three gates skip on CI

On-device recognition needs the user's permission. A headless CI runner cannot grant it, so the
three recognition gates report **SKIP** there, never PASS. They run wherever permission has been given:

```bash
scripts/build-local.sh
scripts/tml-app.sh authorize     # system dialog
scripts/tml-app.sh run           # all 14 gates
```

Two macOS details:
- **Run it as an app.** A bare command-line tool inherits its launcher's privacy identity (Terminal, an IDE, an agent host). If that app has no `NSSpeechRecognitionUsageDescription`, TCC kills the process (SIGABRT, namespace TCC), which is what happened first here. `tml-app.sh` wraps `tml` in a signed `TimelineML.app` so the request is its own.
- **Permission does not survive a rebuild.** An ad-hoc signature changes with every build, and TCC ties the grant to it, so each rebuild asks again. A stable signing identity (Apple Development) avoids this on a Jenkins agent.

The search and timeline logic is still gated on CI (`transcript.timeline-mapping`), using the
golden transcript.

## Run it

```bash
scripts/build-local.sh && .build/local/tml      # Command Line Tools only
python3 tools/fault_matrix.py
swift test -c release -Xswiftc -enable-testing  # XCTest (needs Xcode)
```

## Limits

- **Synthetic audio.** The grooves have exact beats by construction. Real music, with rubato, no drums, or beats on syncopations, needs a licensed annotated set run through the same gates.
- **Synthetic speech.** One synthesized voice, clean, in English. Accents, noise, music beds and overlapping speakers are not covered.
