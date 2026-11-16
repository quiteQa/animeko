#if canImport(NativePlaybackSupport)
@testable import NativePlaybackSupport
#endif
import Testing

struct MediaTransportPolicyTests {
    @Test func rangesSupportSeekAndSuffixWithoutOverflow() throws {
        #expect(try HTTPByteRange.resolve("bytes=50-999", size: 100).count == 50)
        #expect(try HTTPByteRange.resolve("bytes=-20", size: 100).offset == 80)
        #expect(try HTTPByteRange.resolve("bytes=99-", size: 100).contentRange == "bytes 99-99/100")
        #expect(try HTTPByteRange.resolve(nil, size: 0).count == 0)
    }
    @Test(arguments: ["bytes=100-", "bytes=9-1", "bytes=-0", "bytes=0-1,4-5", "bytes=+1-2", "bytes=9999999999999999999999-"])
    func invalidRangesAreRejected(_ header: String) {
        #expect(throws: HTTPByteRange.Invalid.self) { try HTTPByteRange.resolve(header, size: 100) }
    }
    @Test func timelinePausesChangesSpeedAndMapsSeekDiscontinuities() {
        var timeline = PlaybackTimeline()
        _ = timeline.update(position: 10, duration: 100, speed: 1, paused: false, hostTime: 50)
        #expect(timeline.mediaTime(at: 52) == 12)
        _ = timeline.update(position: 12, duration: 100, speed: 1, paused: true, hostTime: 52)
        #expect(timeline.mediaTime(at: 60) == 12)
        _ = timeline.update(position: 12, duration: 100, speed: 2, paused: false, hostTime: 60)
        #expect(timeline.mediaTime(at: 62) == 16)
        _ = timeline.update(position: 70, duration: 100, speed: 2, paused: false, hostTime: 63)
        #expect(timeline.mediaTime(at: 64) == 72)
        #expect(timeline.seekTarget(position: 98, offset: 15) == 100)
        #expect(timeline.seekTarget(position: 5, offset: -15) == 0)
        #expect(timeline.seekTarget(position: .infinity, offset: 1) == nil)
    }
    @Test func measurementsAreBoundedAndRecordOnlyCompletedOperations() {
        var measurements = PlaybackMeasurements()
        for _ in 0..<150 { measurements.beginLoad(at: 10); measurements.ready(at: 10.5) }
        #expect(measurements.firstFrames.count == 100)
        measurements.beginSeek(at: 20)
        measurements.ready(at: 20.25)
        #expect(measurements.seeks == [0.25])
        measurements.beginLoad(at: 30)
        measurements.failed()
        measurements.ready(at: 31)
        #expect(measurements.firstFrames.count == 100)
        #expect(measurements.failures == 1)
    }
}
