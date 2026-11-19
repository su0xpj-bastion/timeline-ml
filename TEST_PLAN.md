# Test plan: timeline-ml

Follows the shared [test strategy](https://github.com/su0xpj-bastion/proof-sheet/blob/main/docs/TEST_STRATEGY.md). Real bugs from building it are in [BUGS.md](BUGS.md).

**In scope:** beat detection (snap cuts to music) and on-device transcript search, plus snap-to-frame and broadcast timecode.

**Out of scope:** real music and real voices (needs licensed sets); stem separation; loudness/mastering.

## What must be true, and how it's checked

| Requirement | Priority | How it is checked |
|---|---|---|
| Cuts land on the beat | P0 | beats within 5 ms median and 15 ms p95; snapped frame nearest the true beat at 23.976, 25, 29.97 DF |
| Tempo is right, including through changes and formats | P1 | ±0.5 BPM; AAC round trip; 44.1/48/96 kHz |
| Search finds the word and lands in the right place | P0 | ≥ 90% of queries inside their spoken line; correct time on an edited timeline |
| Speech never leaves the device | P0 | requiresOnDeviceRecognition |
| Recognition quality | P1 | word error rate ≤ 10% |

## How it runs

- **Every push (CI):** all checks, then the fault matrix (each planted bug switched on alone must fail exactly its pinned checks).
- **Locally:** the same checks through the command-line tool (`scripts/build-local.sh`), on a Mac with only the Command Line Tools.

## Exit criteria

All gates pass where speech permission is granted (CI reports the 3 recognition gates as skipped, never passed); the fault matrix is exact (8/8). CI is green on the default branch.

## Risks

- Test media is generated, so every answer is exact. Real-world media needs licensed sets run through the same checks.
- Simulators and CI machines are not real devices. Timing and hardware behaviour need a real-device pass before release.
