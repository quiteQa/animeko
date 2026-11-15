package me.him188.ani.app.iosnative.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackCompletionTrackerTest {
    @Test
    fun `completed playback survives coalesced pause and rewind`() {
        val tracker = PlaybackCompletionTracker()
        tracker.observe(positionMillis = 950_000, durationMillis = 1_000_000, isPlaying = true)
        tracker.observe(positionMillis = 1_000, durationMillis = 1_000_000, isPlaying = false)
        assertTrue(tracker.hasReachedCompletion)
    }

    @Test
    fun `paused near end does not count as playback`() {
        val tracker = PlaybackCompletionTracker()
        tracker.observe(positionMillis = 950_000, durationMillis = 1_000_000, isPlaying = false)
        assertFalse(tracker.hasReachedCompletion)
    }

    @Test
    fun `invalid duration and position do not complete playback`() {
        val tracker = PlaybackCompletionTracker()
        tracker.observe(positionMillis = 1_000, durationMillis = 0, isPlaying = true)
        tracker.observe(positionMillis = 0, durationMillis = 1_000_000, isPlaying = true)
        tracker.observe(positionMillis = 9_000, durationMillis = 9_000, isPlaying = true)
        assertFalse(tracker.hasReachedCompletion)
    }
}
