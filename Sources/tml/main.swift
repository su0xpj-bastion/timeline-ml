import Foundation
import TimelineML

/// tml [run] [gate...] [--json]   run gates
/// tml list | expected
/// tml authorize                  ask for on-device speech recognition permission (system dialog)
let args = Array(CommandLine.arguments.dropFirst())
let verbs = ["run", "list", "expected", "authorize", "transcript"]
let cmd = args.first.flatMap { verbs.contains($0) ? $0 : nil } ?? "run"
let names = args.filter { !$0.hasPrefix("--") && !verbs.contains($0) }

switch cmd {
case "list":
    for g in Gates.all { print("\(g.name)\t\(g.needsSpeech ? "speech" : "")") }
case "expected":
    let m = Dictionary(uniqueKeysWithValues: Gates.expectedFailures.map { ($0.key.rawValue, $0.value.sorted()) })
    print(String(data: try! JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
case "transcript":
    // Words the recognizer heard, with times, against each golden line's span.
    let sp = Golden.speech()
    for (i, s) in sp.spans.enumerated() { print(String(format: "line %d  %6.2f-%6.2f  %@", i, s.start, s.end, s.text)) }
    do {
        let run = try SpeechEngine.transcribe(sp.clip)
        for w in run.words { print(String(format: "  %6.2f +%.2f  %@", w.time, w.duration, w.text)) }
    } catch { print("error: \(error)") }
case "authorize":
    let s = SpeechEngine.requestAuthorization()
    print("speech recognition authorization: \(["notDetermined", "denied", "restricted", "authorized"][s.rawValue])")
default:
    let results = Gates.run(names)
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try! enc.encode(results), encoding: .utf8)!)
    } else {
        for r in results { print("  \(r.status.rawValue.uppercased())  \(r.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(r.detail)") }
        let pass = results.filter { $0.status == .pass }.count, skip = results.filter { $0.status == .skip }.count
        print("\(pass)/\(results.count - skip) gates passed" + (skip > 0 ? ", \(skip) skipped" : "")
              + (Fault.active.isEmpty ? "" : "  [faults: \(Fault.active.map { $0.rawValue }.sorted().joined(separator: ","))]"))
    }
    exit(results.contains { $0.status == .fail } ? 1 : 0)
}
