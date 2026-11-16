#if canImport(NativePlaybackSupport)
@testable import NativePlaybackSupport
#endif
import Foundation
import Testing

@MainActor
struct PlaybackSupportTests {
    /// 可控暂停点: 不依赖 sleep, 也故意不自动响应 Task.cancel.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        private var isWaiting = false
        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
                entered?.resume()
                entered = nil
            }
        }
        func waitUntilEntered() async {
            if isWaiting { return }
            await withCheckedContinuation { entered = $0 }
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    @Test func cancelledResolverCannotPublishAfterSourceChange() async {
        let scope = PlaybackTaskScope()
        let gate = Gate()
        var published: [String] = []
        scope.run { token in
            await gate.wait()
            if scope.accepts(token) { published.append("old") }
        }
        await gate.waitUntilEntered()
        let old = scope.invalidate()
        scope.run { token in
            if scope.accepts(token) { published.append("new") }
        }
        gate.open()
        for task in old { await task.value }
        // 给新的一代一次确定的主线程执行机会.
        await Task.yield()
        #expect(published == ["new"])
    }

    @Test func closeInvalidatesAllFiftyPreviousSessions() async {
        let scope = PlaybackTaskScope()
        var tokens: [PlaybackTaskScope.Token] = []
        for _ in 0..<50 {
            tokens.append(scope.token)
            scope.invalidate()
        }
        #expect(tokens.allSatisfy { !scope.accepts($0) })
        #expect(scope.accepts(scope.token))
        #expect(scope.invalidate().isEmpty)
    }

    @Test func permanentCloseRejectsLateWorkAndNewOperations() async {
        let scope = PlaybackTaskScope()
        let gate = Gate()
        var published = false
        scope.run { token in
            await gate.wait()
            if scope.accepts(token) { published = true }
        }
        await gate.waitUntilEntered()
        let tasks = scope.close()
        scope.run { _ in published = true }
        gate.open()
        for task in tasks { await task.value }
        #expect(!published)
        #expect(!scope.accepts(scope.token))
        #expect(scope.close().isEmpty)
    }

    @Test func slowWriterCoalescesReportsAndFlushesFinalPosition() async {
        let gate = Gate()
        var saved: [Int] = []
        let writer = CoalescingProgressWriter<Int> { value in
            saved.append(value)
            if value == 1 { await gate.wait() }
        }
        writer.submit(1)
        await gate.waitUntilEntered()
        for position in 2...100 { writer.submit(position) }
        gate.open()
        await writer.flush()
        #expect(saved == [1, 100])
        writer.submit(101)
        await writer.flush()
        #expect(saved == [1, 100, 101])
    }

    @Test func headerConfigurationDoesNotRetainPreviousSource() {
        let first = MPVRequestHeaders(["User-Agent": "source-a", "Referer": "https://a.example", "Cookie": "x=a,b"])
        let second = MPVRequestHeaders([:])
        #expect(first.userAgent == "source-a")
        #expect(first.fields == ["Cookie: x=a,b"])
        #expect(second.userAgent.isEmpty)
        #expect(second.referrer.isEmpty)
        #expect(second.fields.isEmpty)
    }

    @Test func headerNamesAreCaseInsensitiveAndNewlinesAreRejected() {
        let headers = MPVRequestHeaders(["uSeR-aGeNt": "ua", "referer": "ref", "X-Bad": "x\r\nInjected: 1"])
        #expect(headers.userAgent == "ua")
        #expect(headers.referrer == "ref")
        #expect(headers.fields.isEmpty)
    }

    @Test func sameCountNewDanmakuAndChangedFiltersHaveDifferentIdentity() {
        let key = DanmakuRenderKey(revision: UUID(), disabledSources: [], showsTop: true, showsBottom: true, showsFloating: true)
        var replacement = key
        replacement.revision = UUID()
        #expect(replacement != key)
        replacement = key
        replacement.disabledSources = ["Dandanplay"]
        #expect(replacement != key)
        replacement = key
        replacement.showsTop = false
        #expect(replacement != key)
    }
    @Test func diagnosticsHideCredentialsAndSignedPaths() {
        let message = "Failed https://user:secret@media.example/private/token/video.m3u8?signature=abc#secret\nAuthorization: Bearer xyz\nCookie: session=123"
        let safe = DiagnosticRedactor.redact(message)
        #expect(safe.contains("https://media.example/<redacted>"))
        for secret in ["user:secret", "private/token", "signature=abc", "Bearer xyz", "session=123"] {
            #expect(!safe.contains(secret))
        }
    }

}
