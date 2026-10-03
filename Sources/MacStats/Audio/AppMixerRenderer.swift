import CoreAudio
import os

/// A single channel inside an `AudioBufferList`: which buffer, and which
/// interleaved channel within that buffer.
struct AppMixerChannel: Equatable {
    var buffer: Int
    var channel: Int
}

/// How the aggregate device's buffers are laid out for one mixer session.
///
/// Tap streams follow the main sub-device's own input streams (if any), so
/// they are always the last `tapCount * buffersPerTap` input buffers. The mix
/// is written to the output device's preferred stereo pair; a mono output
/// uses the same channel for both sides.
struct AppMixerLayout: Equatable {
    var tapCount: Int
    var buffersPerTap: Int
    var left: AppMixerChannel
    var right: AppMixerChannel
}

/// Preallocated gain table shared between the UI and the real-time IOProc.
///
/// The writer takes the lock; the IOProc only *tries* it and keeps the last
/// snapshot when it is contended, so the render thread never blocks, allocates
/// or touches ARC-managed state. This is a value of raw pointers on purpose:
/// capturing it in the IOProc block involves no reference counting.
struct AppMixerRenderer {
    let layout: AppMixerLayout
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Written under `lock` by `setGain`; the effective gain (0 when muted).
    private let targets: UnsafeMutablePointer<Float>
    /// Real-time-thread only: last snapshot of `targets`.
    private let snapshot: UnsafeMutablePointer<Float>
    /// Real-time-thread only: gain applied at the end of the previous buffer.
    private let current: UnsafeMutablePointer<Float>

    init(layout: AppMixerLayout, gains: [Float]) {
        precondition(gains.count == layout.tapCount)
        self.layout = layout
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        let count = max(layout.tapCount, 1)
        targets = .allocate(capacity: count)
        snapshot = .allocate(capacity: count)
        current = .allocate(capacity: count)
        targets.initialize(repeating: 0, count: count)
        snapshot.initialize(repeating: 0, count: count)
        current.initialize(repeating: 0, count: count)
        for (index, gain) in gains.enumerated() {
            targets[index] = gain
            snapshot[index] = gain
            current[index] = gain
        }
    }

    /// Only call once the IOProc can no longer run (after `AudioDeviceStop`
    /// and `AudioDeviceDestroyIOProcID`).
    func deallocate() {
        lock.deinitialize(count: 1)
        lock.deallocate()
        targets.deallocate()
        snapshot.deallocate()
        current.deallocate()
    }

    func setGain(_ gain: Float, at index: Int) {
        guard index >= 0, index < layout.tapCount else { return }
        os_unfair_lock_lock(lock)
        targets[index] = gain
        os_unfair_lock_unlock(lock)
    }

    /// IOProc entry point. Real-time safe.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let tapCount = layout.tapCount
        if os_unfair_lock_trylock(lock) {
            snapshot.update(from: targets, count: tapCount)
            os_unfair_lock_unlock(lock)
        }
        Self.mix(
            input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
            output: UnsafeMutableAudioBufferListPointer(output),
            layout: layout,
            gainsFrom: UnsafeBufferPointer(start: current, count: tapCount),
            gainsTo: UnsafeBufferPointer(start: snapshot, count: tapCount)
        )
        current.update(from: snapshot, count: tapCount)
    }

    /// Clears the output, then sums every tap into the output's stereo pair,
    /// ramping each tap's gain linearly from `gainsFrom` to `gainsTo` across
    /// the buffer so slider moves and mutes do not click. Pure and
    /// allocation-free; buffers are interleaved 32-bit float.
    static func mix(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        layout: AppMixerLayout,
        gainsFrom: UnsafeBufferPointer<Float>,
        gainsTo: UnsafeBufferPointer<Float>
    ) {
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard layout.left.buffer < output.count, layout.right.buffer < output.count else { return }
        let leftBuffer = output[layout.left.buffer]
        let rightBuffer = output[layout.right.buffer]
        guard let leftData = leftBuffer.mData, let rightData = rightBuffer.mData,
              leftBuffer.mNumberChannels > layout.left.channel,
              rightBuffer.mNumberChannels > layout.right.channel else { return }
        let leftStride = Int(leftBuffer.mNumberChannels)
        let rightStride = Int(rightBuffer.mNumberChannels)
        let outputFrames = min(
            Int(leftBuffer.mDataByteSize) / (leftStride * MemoryLayout<Float>.size),
            Int(rightBuffer.mDataByteSize) / (rightStride * MemoryLayout<Float>.size)
        )
        let leftOut = leftData.assumingMemoryBound(to: Float.self)
        let rightOut = rightData.assumingMemoryBound(to: Float.self)
        let monoOutput = layout.left == layout.right

        let tapStart = input.count - layout.tapCount * layout.buffersPerTap
        guard layout.buffersPerTap > 0, tapStart >= 0 else { return }

        for tap in 0..<min(layout.tapCount, gainsFrom.count, gainsTo.count) {
            let from = gainsFrom[tap]
            let to = gainsTo[tap]
            if from == 0, to == 0 { continue }
            let first = tapStart + tap * layout.buffersPerTap
            guard let left = channel(0, in: input, from: first, count: layout.buffersPerTap) else { continue }
            let right = channel(1, in: input, from: first, count: layout.buffersPerTap) ?? left
            let frames = min(outputFrames, left.frames, right.frames)
            guard frames > 0 else { continue }
            let step = (to - from) / Float(frames)
            for frame in 0..<frames {
                let gain = from + step * Float(frame)
                let l = left.samples[frame * left.stride + left.offset] * gain
                let r = right.samples[frame * right.stride + right.offset] * gain
                if monoOutput {
                    leftOut[frame * leftStride + layout.left.channel] += (l + r) * 0.5
                } else {
                    leftOut[frame * leftStride + layout.left.channel] += l
                    rightOut[frame * rightStride + layout.right.channel] += r
                }
            }
        }
    }

    private struct SourceChannel {
        let samples: UnsafeMutablePointer<Float>
        let offset: Int
        let stride: Int
        let frames: Int
    }

    /// Finds the `index`-th channel across a tap's consecutive buffers, so
    /// interleaved and non-interleaved tap formats are handled alike.
    private static func channel(
        _ index: Int,
        in list: UnsafeMutableAudioBufferListPointer,
        from first: Int,
        count: Int
    ) -> SourceChannel? {
        var remaining = index
        for bufferIndex in first..<(first + count) {
            let buffer = list[bufferIndex]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            if remaining < channels {
                guard let data = buffer.mData else { return nil }
                return SourceChannel(
                    samples: data.assumingMemoryBound(to: Float.self),
                    offset: remaining,
                    stride: channels,
                    frames: Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
                )
            }
            remaining -= channels
        }
        return nil
    }
}
