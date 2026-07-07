import CoreAudio

/// Multi-stream input staging for the aggregate IOProc.
///
/// The aggregate's input side carries the global tap first, then one stereo
/// pair per exception tap, in `kAudioAggregateDeviceTapListKey` order
/// (verified by Prototypes/MultiTapSpike). Channels are walked sequentially
/// across buffers, so interleaved (one buffer, 2 channels) and planar (two
/// buffers, 1 channel) layouts both work, matching the original staging loop.
enum InputStaging {
    /// Stages the first stereo pair (global tap) into stageL/R, then adds
    /// each subsequent stereo pair (exception tap i) scaled by appGains[i].
    /// Realtime-safe: no allocation, no locks. Returns frames staged
    /// (from the global pair, clamped to maxFrames).
    static func stage(
        inABL: UnsafeMutableAudioBufferListPointer,
        stageL: UnsafeMutablePointer<Float>,
        stageR: UnsafeMutablePointer<Float>,
        appGains: UnsafePointer<Float>,
        maxFrames: Int
    ) -> Int {
        var frames = 0
        var channel = 0
        for buf in inABL {
            let n = max(Int(buf.mNumberChannels), 1)
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let bufFrames = min(Int(buf.mDataByteSize) / (n * 4), maxFrames)
            for ch in 0..<n {
                let pair = channel / 2
                let dst = channel % 2 == 0 ? stageL : stageR
                if pair == 0 {
                    for f in 0..<bufFrames { dst[f] = data[f * n + ch] }
                    frames = max(frames, bufFrames)
                } else if pair - 1 < 16 {
                    let g = appGains[pair - 1]
                    if g != 0 {
                        let count = min(bufFrames, frames)
                        for f in 0..<count { dst[f] += g * data[f * n + ch] }
                    }
                }
                channel += 1
            }
        }
        // Mono input → duplicate to both stage channels (defensive; taps are
        // created stereo).
        if channel == 1 {
            for f in 0..<frames { stageR[f] = stageL[f] }
        }
        return frames
    }
}
