import Foundation

/// Integration bugs, switched on with TML_FAULTS=a,b. Each must fail exactly its pinned gates.
public enum Fault: String, CaseIterable {
    case aacPrimingCompensatedTwice   // app trims 2112 priming samples the decoder already removed
    case assumes48k                   // sample index -> seconds with 48,000 for every file
    case tempoOctaveError             // no tempo prior: half or double tempo wins
    case snapFloorsToFrame            // snap truncates to a frame instead of rounding
    case dropFrameIgnored             // 29.97 timecode counted as 30 non-drop
    case transcriptSourceTimeOnTimeline // search hits reported in source-clip time on an edited timeline
    case synthRateAssumed48k          // 22.05 kHz synthesized speech treated as 48 kHz (no resample)
    case segmentsAssumedOneWord       // a recognizer segment can hold several words ("village forgot that")

    public static var active: Set<Fault> = {
        Set((ProcessInfo.processInfo.environment["TML_FAULTS"] ?? "").split(separator: ",").compactMap { Fault(rawValue: String($0)) })
    }()
    public static func on(_ f: Fault) -> Bool { active.contains(f) }
}
