import CoreAudio
import XCTest
@testable import MacStats

final class AppMixerRendererTests: XCTestCase {
    private let stereo = AppMixerLayout(
        tapCount: 2, buffersPerTap: 1,
        left: AppMixerChannel(buffer: 0, channel: 0),
        right: AppMixerChannel(buffer: 0, channel: 1)
    )

    func testTapsAreSummedWithGainIntoTheOutputPair() {
        let input = TestBufferList([
            (2, [1, 2, 3, 4]),          // tap 0: L1 R2, L3 R4
            (2, [10, 20, 30, 40])       // tap 1
        ])
        let output = TestBufferList([(2, [0, 0, 0, 0])])

        mix(input, output, stereo, from: [1, 0.5], to: [1, 0.5])

        XCTAssertEqual(output.samples(0), [6, 12, 18, 24])
    }

    func testSubDeviceInputStreamsBeforeTheTapsAreIgnored() {
        let layout = AppMixerLayout(tapCount: 1, buffersPerTap: 1, left: stereo.left, right: stereo.right)
        let input = TestBufferList([
            (1, [99, 99]),              // the output device's own microphone stream
            (2, [1, 2, 3, 4])
        ])
        let output = TestBufferList([(2, [0, 0, 0, 0])])

        mix(input, output, layout, from: [1], to: [1])

        XCTAssertEqual(output.samples(0), [1, 2, 3, 4])
    }

    func testMutedTapsContributeNothingAndStaleOutputIsCleared() {
        let input = TestBufferList([(2, [1, 1, 1, 1]), (2, [1, 1, 1, 1])])
        let output = TestBufferList([(2, [7, 7, 7, 7])])

        mix(input, output, stereo, from: [0, 0], to: [0, 0])

        XCTAssertEqual(output.samples(0), [0, 0, 0, 0])
    }

    func testGainChangesRampAcrossTheBuffer() {
        let layout = AppMixerLayout(tapCount: 1, buffersPerTap: 1, left: stereo.left, right: stereo.right)
        let input = TestBufferList([(2, [1, 1, 1, 1, 1, 1, 1, 1])])
        let output = TestBufferList([(2, [Float](repeating: 0, count: 8))])

        mix(input, output, layout, from: [1], to: [0])

        XCTAssertEqual(output.samples(0), [1, 1, 0.75, 0.75, 0.5, 0.5, 0.25, 0.25])
    }

    func testMonoOutputAveragesBothChannels() {
        let layout = AppMixerLayout(
            tapCount: 1, buffersPerTap: 1,
            left: AppMixerChannel(buffer: 0, channel: 0),
            right: AppMixerChannel(buffer: 0, channel: 0)
        )
        let input = TestBufferList([(2, [1, 3, 2, 4])])
        let output = TestBufferList([(1, [0, 0])])

        mix(input, output, layout, from: [1], to: [1])

        XCTAssertEqual(output.samples(0), [2, 3])
    }

    func testNonInterleavedTapsAndAPreferredPairInALaterBuffer() {
        let layout = AppMixerLayout(
            tapCount: 1, buffersPerTap: 2,
            left: AppMixerChannel(buffer: 1, channel: 0),
            right: AppMixerChannel(buffer: 1, channel: 1)
        )
        let input = TestBufferList([(1, [1, 2]), (1, [3, 4])])
        let output = TestBufferList([(2, [5, 5, 5, 5]), (2, [0, 0, 0, 0])])

        mix(input, output, layout, from: [1], to: [1])

        XCTAssertEqual(output.samples(0), [0, 0, 0, 0])
        XCTAssertEqual(output.samples(1), [1, 3, 2, 4])
    }

    func testMissingTapBuffersProduceSilenceInsteadOfReadingOtherStreams() {
        let input = TestBufferList([(2, [1, 1, 1, 1])])   // two taps expected, one buffer present
        let output = TestBufferList([(2, [3, 3, 3, 3])])

        mix(input, output, stereo, from: [1, 1], to: [1, 1])

        XCTAssertEqual(output.samples(0), [0, 0, 0, 0])
    }

    func testRendererPicksUpGainChangesAndRampsTowardsThem() {
        let layout = AppMixerLayout(tapCount: 1, buffersPerTap: 1, left: stereo.left, right: stereo.right)
        let renderer = AppMixerRenderer(layout: layout, gains: [1])
        defer { renderer.deallocate() }
        let input = TestBufferList([(2, [1, 1, 1, 1])])
        let output = TestBufferList([(2, [0, 0, 0, 0])])

        renderer.setGain(0, at: 0)
        renderer.render(input: input.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0), [1, 1, 0.5, 0.5])

        renderer.render(input: input.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.samples(0), [0, 0, 0, 0])

        renderer.setGain(2, at: 5) // out of range: ignored
    }

    func testChannelLocationAcrossBuffers() {
        XCTAssertEqual(AppMixerCoreAudio.locate(channel: 0, in: [2, 2]), AppMixerChannel(buffer: 0, channel: 0))
        XCTAssertEqual(AppMixerCoreAudio.locate(channel: 3, in: [2, 2]), AppMixerChannel(buffer: 1, channel: 1))
        XCTAssertNil(AppMixerCoreAudio.locate(channel: 4, in: [2, 2]))
    }

    private func mix(_ input: TestBufferList, _ output: TestBufferList, _ layout: AppMixerLayout, from: [Float], to: [Float]) {
        from.withUnsafeBufferPointer { from in
            to.withUnsafeBufferPointer { to in
                AppMixerRenderer.mix(input: input.list, output: output.list, layout: layout, gainsFrom: from, gainsTo: to)
            }
        }
    }
}

/// An interleaved 32-bit float `AudioBufferList` with owned sample storage.
private final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer

    var unsafePointer: UnsafePointer<AudioBufferList> { UnsafePointer(list.unsafeMutablePointer) }

    init(_ buffers: [(channels: Int, samples: [Float])]) {
        list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        for (index, buffer) in buffers.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: buffer.samples.count)
            data.initialize(from: buffer.samples, count: buffer.samples.count)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(buffer.channels),
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
        }
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func samples(_ index: Int) -> [Float] {
        let buffer = list[index]
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Float.self), count: count))
    }
}
