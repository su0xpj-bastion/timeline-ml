import AVFoundation
import Foundation

/// Mono float audio with its sample rate. Every time in this package is in seconds of *this* clip
/// unless a name says otherwise (timeline time, frames).
public struct Clip {
    public var samples: [Float]
    public var rate: Double
    public init(_ samples: [Float], rate: Double) { self.samples = samples; self.rate = rate }
    public var duration: Double { Double(samples.count) / rate }
}

public enum AudioError: Error { case io(String) }

public enum AudioIO {
    /// Write WAV (PCM 16) or AAC in .m4a.
    public static func write(_ c: Clip, to url: URL, aac: Bool = false) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: c.rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: c.rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
               AVLinearPCMIsFloatKey: false]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: c.rate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(c.samples.count))!
        buf.frameLength = buf.frameCapacity
        c.samples.withUnsafeBufferPointer { buf.floatChannelData![0].assign(from: $0.baseAddress!, count: c.samples.count) }
        try f.write(from: buf)
    }

    /// Decode any file AVFoundation reads (WAV, AAC, ...) to mono float at its native rate.
    /// AVAssetReader applies the file's edit list, which is what removes AAC encoder priming.
    public static func read(_ url: URL) throws -> Clip {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let fd = track.formatDescriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd as! CMAudioFormatDescription)?.pointee
        else { throw AudioError.io("no audio in \(url.lastPathComponent)") }
        let rate = asbd.mSampleRate
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(out)
        guard reader.startReading() else { throw AudioError.io("\(String(describing: reader.error))") }
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb) / 4
            var chunk = [Float](repeating: 0, count: n)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
            samples += chunk
        }
        if Fault.on(.aacPrimingCompensatedTwice) && url.pathExtension == "m4a" {
            // The classic: the decoder already trimmed priming, and the app trims 2112 samples again.
            samples.removeFirst(min(2112, samples.count))
        }
        return Clip(samples, rate: rate)
    }

    /// Sample-rate conversion with AVAudioConverter (used for 22.05 kHz synthesized speech -> 48 kHz).
    public static func resample(_ c: Clip, to rate: Double) -> Clip {
        guard c.rate != rate else { return c }
        let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: c.rate, channels: 1, interleaved: false)!
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: inFmt, to: outFmt)!
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(c.samples.count))!
        inBuf.frameLength = inBuf.frameCapacity
        c.samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].assign(from: $0.baseAddress!, count: c.samples.count) }
        let cap = AVAudioFrameCount(Double(c.samples.count) * rate / c.rate) + 4096
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        _ = conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        let n = Int(outBuf.frameLength)
        return Clip(Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n)), rate: rate)
    }
}
