import AVFoundation
import Foundation

/// Loads impulse-response audio files for the convolution stage,
/// resampling to the engine rate when needed.
enum IRLoader {
    struct LoadError: LocalizedError {
        let errorDescription: String?
        init(_ msg: String) { errorDescription = msg }
    }

    static func load(url: URL, targetSampleRate: Double,
                     maxTaps: Int = 131_072) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        // Only 1–2 channels are ever used; a hostile header claiming
        // hundreds of channels would multiply the read-buffer allocation.
        guard format.channelCount >= 1, format.channelCount <= 8 else {
            throw LoadError("Unsupported channel count (\(format.channelCount))")
        }
        let frames = AVAudioFrameCount(min(file.length, 2_000_000))
        guard frames > 0,
              let readBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw LoadError("Empty or unreadable audio file")
        }
        try file.read(into: readBuf)

        var buffer = readBuf
        if abs(format.sampleRate - targetSampleRate) > 0.5 {
            guard let dstFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
                    channels: format.channelCount, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: dstFormat),
                  let dst = AVAudioPCMBuffer(
                    pcmFormat: dstFormat,
                    frameCapacity: AVAudioFrameCount(
                        Double(readBuf.frameLength) * targetSampleRate / format.sampleRate) + 1024)
            else { throw LoadError("Could not resample IR to \(Int(targetSampleRate)) Hz") }

            var fed = false
            var convErr: NSError?
            converter.convert(to: dst, error: &convErr) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return readBuf
            }
            if let convErr { throw convErr }
            buffer = dst
        }

        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw LoadError("No audio data in IR file")
        }
        let n = min(Int(buffer.frameLength), maxTaps)
        return (0..<min(Int(buffer.format.channelCount), 2)).map { ch in
            Array(UnsafeBufferPointer(start: data[ch], count: n))
        }
    }
}
