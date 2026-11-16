#if canImport(NativePlaybackSupport)
@testable import NativePlaybackSupport
#endif
import Testing

struct FrameProbePolicyTests {
    @Test func knownSDRCanEnterTheFrameProbe() {
        #expect(FrameProbeColor(primaries: "bt.709", transfer: "bt.1886", dolbyVisionProfile: nil).verdict == .sdr)
    }

    @Test(arguments: ["pq", "smpte2084", "hlg", "arib-std-b67"])
    func hdrNeverEntersTheEightBitProbe(_ transfer: String) {
        let result = FrameProbeColor(primaries: "bt.2020", transfer: transfer, dolbyVisionProfile: nil).verdict
        if case .blocked = result {} else { Issue.record("HDR must be blocked") }
    }

    @Test(arguments: [5, 7, 8])
    func dolbyVisionIsBlockedEvenIfTransferAppearsSDR(_ profile: Int) {
        let result = FrameProbeColor(primaries: "bt.709", transfer: "bt.1886", dolbyVisionProfile: profile).verdict
        if case .blocked = result {} else { Issue.record("Dolby Vision must be blocked") }
    }

    @Test func missingMetadataIsNotAssumedToBeSDR() {
        let result = FrameProbeColor(primaries: nil, transfer: nil, dolbyVisionProfile: nil).verdict
        if case .blocked = result {} else { Issue.record("Unknown metadata must be blocked") }
    }

    @Test func presentationTimestampPreservesMpvTargetAndRejectsDiscontinuity() {
        #expect(FrameProbeClock.presentationSeconds(targetMicroseconds: 10_020_000, mpvNowMicroseconds: 10_000_000, hostNowSeconds: 100) == 100.02)
        #expect(FrameProbeClock.presentationSeconds(targetMicroseconds: 0, mpvNowMicroseconds: 10_000_000, hostNowSeconds: 100) == 100)
        #expect(FrameProbeClock.presentationSeconds(targetMicroseconds: .max, mpvNowMicroseconds: .min, hostNowSeconds: 100) == 100)
    }
}
