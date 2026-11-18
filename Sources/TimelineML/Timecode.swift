import Foundation

/// Editorial frame rates. 23.976/29.97/59.94 are 24000/1001 etc.; 29.97 and 59.94 drop-frame
/// skip frame *numbers* (not frames) so the timecode tracks the wall clock.
public enum FrameRate: String, CaseIterable {
    case fps23_976 = "23.976", fps24 = "24", fps25 = "25", fps29_97DF = "29.97 DF", fps30 = "30", fps59_94DF = "59.94 DF"

    public var exact: Double {
        switch self {
        case .fps23_976: return 24000.0 / 1001
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97DF: return 30000.0 / 1001
        case .fps30: return 30
        case .fps59_94DF: return 60000.0 / 1001
        }
    }
    public var nominal: Int { Int(exact.rounded()) }
    public var dropFrame: Bool { (self == .fps29_97DF || self == .fps59_94DF) && !Fault.on(.dropFrameIgnored) }
}

public enum Timecode {
    /// The frame a time falls in, for display and for snapping a cut. Rounds to the nearest frame.
    public static func frame(_ seconds: Double, _ r: FrameRate) -> Int {
        let f = seconds * r.exact
        return Fault.on(.snapFloorsToFrame) ? Int(f.rounded(.down)) : Int(f.rounded())
    }

    /// HH:MM:SS:FF (non-drop) or HH:MM:SS;FF (drop-frame).
    public static func string(frame f: Int, _ r: FrameRate) -> String {
        var n = f
        let fps = r.nominal
        if r.dropFrame {
            let drop = fps == 60 ? 4 : 2
            let perMin = fps * 60 - drop, per10 = fps * 600 - drop * 9
            let d = n / per10, m = n % per10
            n += drop * 9 * d + (m > drop ? drop * ((m - drop) / perMin) : 0)
        }
        let ff = n % fps, s = n / fps
        return String(format: "%02d:%02d:%02d%@%02d", s / 3600, (s / 60) % 60, s % 60, r.dropFrame ? ";" : ":", ff)
    }
}

/// Snap a cut to the music: move it to the nearest detected beat, then to that beat's frame.
public enum Snap {
    public static func cut(_ t: Double, beats: [Double], _ r: FrameRate, maxDistance: Double = 0.25) -> Int {
        guard let b = beats.min(by: { abs($0 - t) < abs($1 - t) }), abs(b - t) <= maxDistance else { return Timecode.frame(t, r) }
        return Timecode.frame(b, r)
    }
}
