import AVFoundation
import CoreVideo
import Libmpv
import XCTest
@testable import NativeMediaHost

@MainActor
final class MediaRuntimeTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4")) }

    func testLoopbackSupportsRangeSuffixHeadAndRevocation() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let source = MediaDataSource(data: data, contentType: "video/mp4")
        let endpoint = try await MediaHTTPServer.shared.register { _ in source }
        defer { MediaHTTPServer.shared.remove(endpoint) }
        var request = URLRequest(url: endpoint.url()); request.setValue("bytes=16380-16410", forHTTPHeaderField: "Range")
        let (part, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 16380-16410/200000")
        XCTAssertEqual(part, data.subdata(in: 16380..<16411))
        request.setValue("bytes=-17", forHTTPHeaderField: "Range")
        let (suffix, _) = try await URLSession.shared.data(for: request); XCTAssertEqual(suffix, data.suffix(17))
        request.httpMethod = "HEAD"
        let (head, headResponse) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(head.isEmpty); XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "17")
        request.httpMethod = "GET"; request.setValue("bytes=200000-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request); XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 416)
        MediaHTTPServer.shared.remove(endpoint)
        let (_, revoked) = try await URLSession.shared.data(from: endpoint.url()); XCTAssertEqual((revoked as? HTTPURLResponse)?.statusCode, 404)
    }

    func testSoftwareMpvFramesHavePixelsAndBoundedRetention() async throws {
        let handle = try XCTUnwrap(mpv_create())
        XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "vo", "libmpv"), 0)
        XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "ao", "null"), 0)
        XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "hwdec", "no"), 0)
        XCTAssertGreaterThanOrEqual(mpv_set_option_string(handle, "keep-open", "yes"), 0)
        XCTAssertGreaterThanOrEqual(mpv_initialize(handle), 0)
        let state = VideoFrameState(); let generation = UUID(); let epoch = UUID()
        state.update { $0.generation = generation; $0.epoch = epoch; $0.metadataReady = true; $0.width = 640; $0.height = 360; $0.color = FrameProbeColor(primaries: "bt.709", transfer: "bt.709", dolbyVisionProfile: nil) }
        var held: [VideoFrame] = []; var phase = 0; var errors: [String] = []
        let full = expectation(description: "three buffers retained")
        let noFourth = expectation(description: "pool bounded at three"); noFourth.isInverted = true
        let resumed = expectation(description: "frame output resumes")
        let output = MPVSampleBufferOutput(state: state, receive: { frame in
            switch phase {
            case 0: held.append(frame); if held.count == 3 { phase = 1; full.fulfill() }
            case 1: noFourth.fulfill()
            case 2: phase = 3; resumed.fulfill()
            default: break
            }
        }, failure: { message in Task { @MainActor in errors.append(message) } })
        let error: String? = await withCheckedContinuation { continuation in output.initialize(handle: handle) { continuation.resume(returning: $0) } }
        XCTAssertNil(error)
        let load = "loadfile \"\(try fixture("sdr-pattern").path)\" replace"
        XCTAssertGreaterThanOrEqual(load.withCString { mpv_command_string(handle, $0) }, 0)
        await fulfillment(of: [full], timeout: 15)
        if let frame = held.first {
            XCTAssertEqual(frame.generation, generation); XCTAssertEqual(frame.epoch, epoch)
            CVPixelBufferLockBaseAddress(frame.buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(frame.buffer) {
                let stride = CVPixelBufferGetBytesPerRow(frame.buffer)
                let top = base.advanced(by: 30 * stride + 320 * 4).assumingMemoryBound(to: UInt8.self)
                let bottom = base.advanced(by: 330 * stride + 320 * 4).assumingMemoryBound(to: UInt8.self)
                XCTAssertGreaterThan(Int(top[2]), Int(top[0]) + 100)
                XCTAssertGreaterThan(Int(bottom[0]), Int(bottom[2]) + 100)
            } else { XCTFail("missing pixels") }
            CVPixelBufferUnlockBaseAddress(frame.buffer, .readOnly)
        } else { XCTFail("no rendered frames") }
        await fulfillment(of: [noFourth], timeout: 0.2)
        phase = 2; held.removeAll(); output.requestFrame(force: true)
        await fulfillment(of: [resumed], timeout: 3)
        state.update { $0.metadataReady = false }
        await withCheckedContinuation { continuation in output.close { continuation.resume() } }
        mpv_terminate_destroy(handle)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: ", "))
    }

    func testNativeProbeAndHLSConversionProducePlayableSDRSegments() async throws {
        let url = try fixture("sdr-pattern").absoluteString
        let info = try await MediaInspection.inspect(url: url, headers: [:])
        XCTAssertFalse(info.isHDR); XCTAssertEqual(info.width, 640)
        let writer = try AirPlayHLSWriter(url: url, headers: [:], info: info, start: 0, compatible1080: false)
        defer { writer.cancel(); writer.cleanup() }
        await writer.run()
        let source = try await writer.resource("index.m3u8")
        let data = try await source.read(offset: 0, count: Int(source.size))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST")); XCTAssertTrue(text.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        let name = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasSuffix(".m4s") })
        let initData = try Data(contentsOf: writer.directory.appendingPathComponent("init.mp4"))
        let segmentData = try Data(contentsOf: writer.directory.appendingPathComponent(name))
        let combined = writer.directory.appendingPathComponent("probe.mp4")
        try (initData + segmentData).write(to: combined)
        let converted = try await MediaInspection.inspect(url: combined.absoluteString, headers: [:])
        XCTAssertEqual(converted.width, info.width); XCTAssertEqual(converted.height, info.height); XCTAssertFalse(converted.isHDR)
    }

    func testHDRPreflightRejectsEightBitAirPlayConversion() async throws {
        let url = try fixture("hdr10-pattern").absoluteString
        let info = try await MediaInspection.inspect(url: url, headers: [:]); XCTAssertTrue(info.isHDR)
        XCTAssertThrowsError(try AirPlayHLSWriter(url: url, headers: [:], info: info, start: 0, compatible1080: false))
    }
}
