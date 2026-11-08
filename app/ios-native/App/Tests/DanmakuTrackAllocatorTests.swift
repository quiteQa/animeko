import Testing

struct DanmakuTrackAllocatorTests {
    private func makeAllocator(floating: Int = 2, fixed: Int = 1) -> DanmakuTrackAllocator {
        DanmakuTrackAllocator(config: .init(
            floatingTrackCount: floating,
            fixedTrackCount: fixed,
            viewportWidth: 800,
            floatingDuration: 8,
            fixedDuration: 5,
        ))
    }

    @Test func firstFloatingDanmakuTakesFirstTrack() {
        var allocator = makeAllocator()
        #expect(allocator.allocateFloating(width: 100, at: 0) == 0)
    }

    @Test func overlappingFloatingDanmakuUsesNextTrack() {
        var allocator = makeAllocator()
        _ = allocator.allocateFloating(width: 100, at: 0)
        // 前一条还没完全进入屏幕
        #expect(allocator.allocateFloating(width: 100, at: 0.1) == 1)
    }

    @Test func floatingDanmakuIsDroppedWhenAllTracksAreBusy() {
        var allocator = makeAllocator()
        _ = allocator.allocateFloating(width: 100, at: 0)
        _ = allocator.allocateFloating(width: 100, at: 0)
        #expect(allocator.allocateFloating(width: 100, at: 0.1) == nil)
    }

    @Test func trackIsReusedAfterPreviousDanmakuHasEntered() {
        var allocator = makeAllocator(floating: 1)
        _ = allocator.allocateFloating(width: 100, at: 0)
        // 速度 (800 + 100) / 8 = 112.5, 约 0.9 秒后完全进入; 同宽度的新弹幕追不上
        #expect(allocator.allocateFloating(width: 100, at: 1) == 0)
    }

    @Test func fasterDanmakuDoesNotReuseTrackItWouldCatchUp() {
        var allocator = makeAllocator(floating: 1)
        _ = allocator.allocateFloating(width: 50, at: 0)
        // 更长的弹幕速度更快, 会在前一条离开前追上它
        #expect(allocator.allocateFloating(width: 600, at: 1) == nil)
    }

    @Test func fixedTrackIsFreedAfterDuration() {
        var allocator = makeAllocator()
        #expect(allocator.allocateFixed(isTop: true, at: 0) == 0)
        #expect(allocator.allocateFixed(isTop: true, at: 1) == nil)
        #expect(allocator.allocateFixed(isTop: false, at: 1) == 0)
        #expect(allocator.allocateFixed(isTop: true, at: 5) == 0)
    }

    @Test func resetFreesAllTracks() {
        var allocator = makeAllocator(floating: 1)
        _ = allocator.allocateFloating(width: 100, at: 0)
        allocator.reset()
        #expect(allocator.allocateFloating(width: 100, at: 0) == 0)
    }
}
