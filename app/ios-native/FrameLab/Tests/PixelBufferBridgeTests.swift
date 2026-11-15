import CoreMedia
import CoreVideo
import XCTest
@testable import NativeFrameLab

@MainActor
final class PixelBufferBridgeTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
    }

    func testSDRFramesHaveCorrectOrientationAndHostTimestamps() async throws {
        let framesReady = expectation(description: "three decoded SDR frames")
        var frames: [ProbeFrame] = []
        var errors: [String] = []
        var completed = false
        let engine = FrameProbeEngine(receive: { _, event in
            if case .failed(let message) = event {
                errors.append(message)
                if !completed { completed = true; framesReady.fulfill() }
            }
        }, frames: { frame in
            if !completed {
                frames.append(frame)
                if frames.count == 3 { completed = true; framesReady.fulfill() }
            }
        })
        engine.open(try fixture("sdr-pattern"), generation: UUID())
        await fulfillment(of: [framesReady], timeout: 30)
        await withCheckedContinuation { continuation in engine.close { continuation.resume() } }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: ", "))
        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(first.buffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(first.buffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(first.buffer), 360)
        XCTAssertTrue(first.hostTime.isNumeric)
        for pair in zip(frames, frames.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.hostTime.seconds, pair.1.hostTime.seconds) }
        CVPixelBufferLockBaseAddress(first.buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(first.buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(first.buffer))
        let stride = CVPixelBufferGetBytesPerRow(first.buffer)
        let top = base.advanced(by: 30 * stride + 320 * 4).assumingMemoryBound(to: UInt8.self)
        let bottom = base.advanced(by: 330 * stride + 320 * 4).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(Int(top[2]), Int(top[0]) + 100, "top must be red")
        XCTAssertGreaterThan(Int(bottom[0]), Int(bottom[2]) + 100, "bottom must be blue")
    }

    func testHDRIsBlockedBeforeAnyEightBitFrameIsDelivered() async throws {
        let blocked = expectation(description: "HDR policy blocks input")
        let noFrames = expectation(description: "no downgraded HDR frame")
        noFrames.isInverted = true
        var reported = false
        let engine = FrameProbeEngine(receive: { _, event in
            if case .metadata(let color) = event, case .blocked = color.verdict, !reported {
                reported = true
                blocked.fulfill()
            }
        }, frames: { _ in noFrames.fulfill() })
        engine.open(try fixture("hdr10-pattern"), generation: UUID())
        await fulfillment(of: [blocked], timeout: 30)
        await fulfillment(of: [noFrames], timeout: 0.5)
        await withCheckedContinuation { continuation in engine.close { continuation.resume() } }
    }

    func testUnspecifiedSourceMetadataIsNotReplacedWithMpvDefaults() async throws {
        let color = try ProbeInputColor.inspect(fixture("unknown-color"))
        XCTAssertNil(color.primaries)
        XCTAssertNil(color.transfer)
        if case .blocked = color.verdict {} else { XCTFail("unspecified input must be blocked") }
    }

    func testRetainingThreeBuffersAppliesBackpressureAndReleasingThemResumesOutput() async throws {
        let full = expectation(description: "pool reaches three retained buffers")
        let resumed = expectation(description: "rendering resumes after release")
        var held: [ProbeFrame] = []
        let noExtraFrame = expectation(description: "no fourth retained buffer")
        noExtraFrame.isInverted = true
        var phase = 0 // collecting, holding, resuming, finished
        var errors: [String] = []
        let engine = FrameProbeEngine(receive: { _, event in
            if case .failed(let message) = event {
                errors.append(message)
                if phase == 0 { phase = 3; full.fulfill() }
            }
        }, frames: { frame in
            switch phase {
            case 0:
                held.append(frame)
                if held.count == 3 { phase = 1; full.fulfill() }
            case 1: noExtraFrame.fulfill()
            case 2: phase = 3; resumed.fulfill()
            default: break
            }
        })
        engine.open(try fixture("sdr-pattern"), generation: UUID())
        await fulfillment(of: [full], timeout: 30)
        guard errors.isEmpty, held.count == 3 else {
            await withCheckedContinuation { continuation in engine.close { continuation.resume() } }
            XCTFail("frame pool did not fill: \(errors.joined(separator: ", "))")
            return
        }
        await fulfillment(of: [noExtraFrame], timeout: 0.15)
        phase = 2
        held.removeAll()
        await fulfillment(of: [resumed], timeout: 2)
        await withCheckedContinuation { continuation in engine.close { continuation.resume() } }
    }
}
