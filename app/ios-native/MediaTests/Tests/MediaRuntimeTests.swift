import AVFoundation
import CoreVideo
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
        let generation = UUID(); let epoch = UUID()
        var held: [VideoFrame] = []; var phase = 0; var errors: [String] = []
        let full = expectation(description: "three buffers retained")
        let noFourth = expectation(description: "pool bounded at three"); noFourth.isInverted = true
        let resumed = expectation(description: "frame output resumes")
        let output = try SoftwareRenderHarness(generation: generation, epoch: epoch, receive: { frame in
            switch phase {
            case 0: held.append(frame); if held.count == 3 { phase = 1; full.fulfill() }
            case 1: noFourth.fulfill()
            case 2: phase = 3; resumed.fulfill()
            default: break
            }
        }, failure: { message in errors.append(message) })
        try await output.open(fixture("sdr-pattern"))
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
        phase = 2; held.removeAll(); output.requestFrame()
        await fulfillment(of: [resumed], timeout: 3)
        await output.close()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: ", "))
    }

    func testNativeProbeAndHLSConversionProducePlayableSDRSegments() async throws {
        let url = try fixture("sdr-pattern").absoluteString
        let info = try await MediaInspection.inspect(url: url, headers: [:])
        XCTAssertFalse(info.isHDR); XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 90)
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

    func testStereoAudioSurvivesSeekingAndNativeHLSConversion() async throws {
        let url = try fixture("pip-sdr").absoluteString
        let info = try await MediaInspection.inspect(url: url, headers: [:])
        XCTAssertGreaterThan(info.audioChannels, 0)
        let writer = try AirPlayHLSWriter(url: url, headers: [:], info: info,
            start: max(0, info.duration - 3), compatible1080: true)
        defer { writer.cancel(); writer.cleanup() }
        await writer.run()
        let source = try await writer.resource("index.m3u8")
        let data = try await source.read(offset: 0, count: Int(source.size))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
        let name = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasSuffix(".m4s") })
        let initialization = try Data(contentsOf: writer.directory.appendingPathComponent("init.mp4"))
        let segment = try Data(contentsOf: writer.directory.appendingPathComponent(name))
        let file = writer.directory.appendingPathComponent("audio-check.mp4")
        try (initialization + segment).write(to: file)
        let result = try await MediaInspection.inspect(url: file.absoluteString, headers: [:])
        XCTAssertEqual(result.audioChannels, 2)
        XCTAssertGreaterThan(result.duration, 2)
        XCTAssertLessThan(result.duration, 4)
    }

    func testVODTimebaseStopsWhenPausedAndAppliesPlaybackRate() throws {
        let pip = MPVPictureInPicture()
        pip.update(position: 10, duration: 60, speed: 2, paused: true)
        let timebase = try XCTUnwrap(pip.view.displayLayer.controlTimebase)
        XCTAssertEqual(CMTimebaseGetRate(timebase), 0)
        XCTAssertEqual(CMTimebaseGetTime(timebase).seconds, 10, accuracy: 0.001)
        pip.update(position: 10, duration: 60, speed: 2, paused: false)
        XCTAssertEqual(CMTimebaseGetRate(timebase), 2)
        pip.update(position: 40, duration: 60, speed: 0.5, paused: true)
        XCTAssertEqual(CMTimebaseGetTime(timebase).seconds, 40, accuracy: 0.001)
        pip.reset()
    }

    func testHDRPreflightRejectsEightBitAirPlayConversion() async throws {
        let url = try fixture("hdr10-pattern").absoluteString
        let info = try await MediaInspection.inspect(url: url, headers: [:]); XCTAssertTrue(info.isHDR)
        XCTAssertThrowsError(try AirPlayHLSWriter(url: url, headers: [:], info: info, start: 0, compatible1080: false))
    }
}
