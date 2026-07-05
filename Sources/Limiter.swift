import Foundation

// MARK: - Stereo lookahead limiter
//
// Replaces the old hard clipper: a sliding-window-minimum gain computer with
// instant attack (the gain is already down when the peak arrives, thanks to
// the lookahead delay) and smooth exponential release. Channels are linked
// (single gain for both) to preserve stereo image. Adds `lookahead` samples
// of latency. No allocation in process() — realtime-safe.

final class Limiter {
    private let lookahead: Int
    private let ceiling: Float
    private let releaseCoef: Float

    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private var delayIdx = 0

    // Monotonic deque over the lookahead window for sliding minimum gain.
    private let dequeIdx: UnsafeMutablePointer<Int>
    private let dequeVal: UnsafeMutablePointer<Float>
    private let dequeCap: Int
    private var dqHead = 0
    private var dqCount = 0

    private var envelope: Float = 1.0
    private var sampleCounter = 0

    init(sampleRate: Double, lookaheadMs: Double = 5, releaseMs: Double = 60,
         ceiling: Float = 0.985) {
        lookahead = max(1, Int(sampleRate * lookaheadMs / 1000))
        self.ceiling = ceiling
        releaseCoef = Float(1.0 - exp(-1.0 / (releaseMs / 1000 * sampleRate)))
        delayL = .allocate(capacity: lookahead)
        delayL.initialize(repeating: 0, count: lookahead)
        delayR = .allocate(capacity: lookahead)
        delayR.initialize(repeating: 0, count: lookahead)
        dequeCap = lookahead + 1
        dequeIdx = .allocate(capacity: dequeCap)
        dequeIdx.initialize(repeating: 0, count: dequeCap)
        dequeVal = .allocate(capacity: dequeCap)
        dequeVal.initialize(repeating: 1, count: dequeCap)
    }

    deinit {
        delayL.deallocate()
        delayR.deallocate()
        dequeIdx.deallocate()
        dequeVal.deallocate()
    }

    /// Process planar stereo in place.
    func process(l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>,
                 frames: Int) {
        for i in 0..<frames {
            let inL = l[i]
            let inR = r[i]

            // Target gain for this incoming sample
            let peak = max(abs(inL), abs(inR))
            let target: Float = peak > ceiling ? ceiling / peak : 1.0

            // Sliding-window minimum: drop expired head, keep deque increasing.
            // An entry pushed at iteration t constrains outputs up to and
            // including t + lookahead (when its own delayed sample exits).
            while dqCount > 0, dequeIdx[dqHead] < sampleCounter - lookahead {
                dqHead = (dqHead + 1) % dequeCap
                dqCount -= 1
            }
            while dqCount > 0,
                  dequeVal[(dqHead + dqCount - 1) % dequeCap] >= target {
                dqCount -= 1
            }
            let tail = (dqHead + dqCount) % dequeCap
            dequeIdx[tail] = sampleCounter
            dequeVal[tail] = target
            dqCount += 1

            let windowMin = dequeVal[dqHead]

            // Instant attack, exponential release
            if windowMin < envelope {
                envelope = windowMin
            } else {
                envelope += releaseCoef * (windowMin - envelope)
            }

            // Delayed audio × gain (+ hard safety clamp)
            var outL = delayL[delayIdx] * envelope
            var outR = delayR[delayIdx] * envelope
            if outL > 1.0 { outL = 1.0 } else if outL < -1.0 { outL = -1.0 }
            if outR > 1.0 { outR = 1.0 } else if outR < -1.0 { outR = -1.0 }
            delayL[delayIdx] = inL
            delayR[delayIdx] = inR
            delayIdx = (delayIdx + 1) % lookahead
            l[i] = outL
            r[i] = outR
            sampleCounter += 1
        }
    }
}
