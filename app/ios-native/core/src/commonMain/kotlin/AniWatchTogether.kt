/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.him188.ani.app.data.network.WatchTogetherJoinException
import me.him188.ani.app.data.network.WatchTogetherJoinFailure
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.domain.watchtogether.LocalPlaybackBridge
import me.him188.ani.app.domain.watchtogether.PlaybackDirective
import me.him188.ani.app.domain.watchtogether.RoomSession
import me.him188.ani.app.domain.watchtogether.SyncAction
import me.him188.ani.app.domain.watchtogether.WatchTogetherConnectionState
import me.him188.ani.app.domain.watchtogether.WatchTogetherEffect
import me.him188.ani.app.domain.watchtogether.WatchTogetherManager
import me.him188.ani.app.domain.watchtogether.WatchTogetherRoomEndReason
import me.him188.ani.app.domain.watchtogether.WatchTogetherState
import me.him188.ani.app.domain.watchtogether.positionAt
import me.him188.ani.client.models.AniWatchTogetherMember
import me.him188.ani.client.models.AniWatchTogetherMemberState
import me.him188.ani.client.models.AniWatchTogetherPlayback
import me.him188.ani.client.models.AniWatchTogetherRoomSnapshot
import me.him188.ani.client.models.AniWatchTogetherWatchingInfo
import org.koin.core.Koin
import kotlin.coroutines.CoroutineContext
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * 一起看. 房间状态与成员来自上游 `WatchTogetherManager`; 播放器通过本类上报本地播放状态, 并接收与房主同步的指令.
 *
 * 播放页在播放期间约每秒调用一次 [reportWatching], 离开时调用 [clearWatching]. 房主或跟随房主的成员会收到
 * [observeDirectives] 的同步指令, 指令中的位置已按服务器时间推算到回调时刻.
 */
class AniWatchTogether internal constructor(
    private val koin: Koin,
    private val scope: CoroutineScope,
    private val callbackContext: CoroutineContext,
) {
    private val manager: WatchTogetherManager by lazy { koin.get() }
    private val bridge: LocalPlaybackBridge by lazy { koin.get() }
    private val settingsRepository: SettingsRepository by lazy { koin.get() }

    /** 观察房间状态. 状态, 成员, 连接或跟随状态变化时回调. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun observeRoom(listener: AniWatchTogetherRoomListener): AniSubscription = scope.launchObserver(
        callbackContext,
        manager.state.flatMapLatest { state -> roomFlow(state) },
    ) { listener.onRoom(it) }

    private fun roomFlow(state: WatchTogetherState): Flow<AniWatchTogetherRoom> = when (state) {
        WatchTogetherState.Disabled -> flowOf(AniWatchTogetherRoom.inactive(AniWatchTogetherStatus.DISABLED))
        WatchTogetherState.Idle -> flowOf(AniWatchTogetherRoom.inactive(AniWatchTogetherStatus.IDLE))
        is WatchTogetherState.Joining -> flowOf(
            AniWatchTogetherRoom.inactive(AniWatchTogetherStatus.JOINING).copy(roomName = state.roomName),
        )

        is WatchTogetherState.InRoom -> state.session.let { session ->
            combine(session.snapshot, session.following, session.connection) { snapshot, following, connection ->
                session.toAniRoom(snapshot, following, connection)
            }
        }
    }

    /** 观察需要提示用户的事件: 房主切换到其他条目, 房间结束, 重连结果等. */
    fun observeEvents(listener: AniWatchTogetherEventListener): AniSubscription {
        val job = scope.launch {
            manager.effects.collect { effect ->
                withContext(callbackContext) {
                    when (effect) {
                        is WatchTogetherEffect.Navigate -> effect.toAniNavigation()?.let { listener.onNavigate(it) }
                        is WatchTogetherEffect.RoomEnded -> listener.onMessage(
                            when (effect.reason) {
                                WatchTogetherRoomEndReason.ROOM_CLOSED -> "房间已关闭"
                                WatchTogetherRoomEndReason.SESSION_REPLACED -> "你已在其他设备加入房间"
                            },
                        )

                        WatchTogetherEffect.Rejoined -> listener.onMessage("已重新加入房间")
                        WatchTogetherEffect.RejoinFailed -> listener.onMessage("重新加入房间失败")
                        is WatchTogetherEffect.ResyncedWithHost -> listener.onMessage(resyncMessage(effect.deltaMillis))
                    }
                }
            }
        }
        return AniSubscription(job)
    }

    /**
     * 观察发给播放器的同步指令. 房主缓冲时等待 2 秒确认仍在缓冲再下发, 避免短暂卡顿让所有人跟着暂停.
     */
    fun observeDirectives(listener: AniWatchTogetherDirectiveListener): AniSubscription {
        val job = scope.launch {
            bridge.directives.collect { directive ->
                val result = when (directive) {
                    is PlaybackDirective.Sync -> settle(directive.playback)?.let {
                        it.toDirective(AniPlaybackDirectiveKind.SYNC, it.info.episodeId, forceSeek = directive.initial)
                    }

                    is PlaybackDirective.SwitchEpisode -> directive.playback.toDirective(
                        AniPlaybackDirectiveKind.SWITCH_EPISODE,
                        directive.episodeId,
                        forceSeek = true,
                    )
                }
                if (result != null) withContext(callbackContext) { listener.onDirective(result) }
            }
        }
        return AniSubscription(job)
    }

    private suspend fun settle(playback: AniWatchTogetherPlayback): AniWatchTogetherPlayback? {
        val host = playback.info
        if (!host.buffering) return playback
        delay(BUFFERING_DEBOUNCE_MILLIS)
        val latest = bridge.targetPlayback.value ?: return null
        val info = latest.info
        return if (info.subjectId == host.subjectId && info.episodeId == host.episodeId && info.buffering) latest else null
    }

    /**
     * 播放器首次加载完成后应同步到的房主状态. 不在房间, 自己是房主或未跟随房主时为 `null`.
     */
    fun initialTarget(): AniPlaybackDirective? =
        bridge.targetPlayback.value?.toDirective(
            AniPlaybackDirectiveKind.SYNC,
            bridge.targetPlayback.value?.info?.episodeId ?: 0,
            forceSeek = true,
        )

    /** 房主与跟随房主的成员参与同步: 首次加载后应先暂停, 等待房主开始播放. */
    fun isSyncActive(): Boolean {
        val state = manager.state.value
        return state is WatchTogetherState.InRoom && (state.session.isHost || state.session.following.value)
    }

    /**
     * 上报本地播放状态. [durationMillis] 未知时传 0, 表示仍在加载.
     */
    fun reportWatching(
        subjectId: Int,
        episodeId: Int,
        subjectName: String,
        episodeSort: String,
        episodeName: String,
        positionMillis: Long,
        durationMillis: Long,
        paused: Boolean,
        buffering: Boolean,
        playbackRate: Float,
    ) {
        bridge.updateLocalWatching(
            AniWatchTogetherWatchingInfo(
                subjectId = subjectId,
                episodeId = episodeId,
                subjectName = subjectName,
                episodeSort = episodeSort,
                episodeName = episodeName,
                positionMillis = positionMillis.coerceAtLeast(0L),
                positionAtMillis = manager.serverNowMillis(),
                durationMillis = durationMillis.coerceAtLeast(0L),
                paused = paused,
                buffering = buffering,
                loading = durationMillis <= 0L,
                playbackRate = playbackRate,
            ),
        )
    }

    /** 离开播放器或切换剧集时调用. */
    fun clearWatching() {
        bridge.updateLocalWatching(null)
    }

    /** 播放器为追上房主而跳转后调用, 用于提示 "已与房主同步". */
    fun notifyCorrectionApplied(deltaMillis: Long) {
        bridge.notifyCorrectionApplied(deltaMillis)
    }

    /** 开启一起看功能. 需要已登录. */
    @Throws(Exception::class)
    suspend fun enable() {
        settingsRepository.watchTogetherSettings.update { copy(enabled = true) }
    }

    /**
     * 加入房间, 房间不存在时创建. 成功返回 `null`, 失败返回给用户看的原因.
     */
    @Throws(Exception::class)
    suspend fun join(roomName: String, password: String): String? {
        val result = manager.join(roomName, password)
        val error = result.exceptionOrNull() ?: return null
        val failure = (error as? WatchTogetherJoinException)?.failure ?: WatchTogetherJoinFailure.TEMPORARY
        return "加入失败: ${failure.describe()}"
    }

    @Throws(Exception::class)
    suspend fun leave() {
        manager.leave()
    }

    @Throws(Exception::class)
    suspend fun setFollowing(following: Boolean) {
        manager.setFollowing(following)
    }

    fun setAppForeground(foreground: Boolean) {
        manager.setAppForeground(foreground)
    }

    /** 上次使用的房间名, 用于预填. */
    @Throws(Exception::class)
    suspend fun lastRoomName(): String {
        return settingsRepository.watchTogetherSettings.flow.first().lastRoomName
    }

    private fun AniWatchTogetherPlayback.toDirective(
        kind: AniPlaybackDirectiveKind,
        episodeId: Int,
        forceSeek: Boolean,
    ): AniPlaybackDirective = AniPlaybackDirective(
        kind = kind,
        subjectId = info.subjectId,
        episodeId = episodeId,
        positionMillis = info.positionAt(manager.serverNowMillis()),
        paused = info.paused,
        playbackRate = info.playbackRate,
        forceSeek = forceSeek,
    )

    private fun WatchTogetherEffect.Navigate.toAniNavigation(): AniWatchTogetherNavigation? {
        val (subjectId, episodeId, position) = when (val action = action) {
            is SyncAction.PushEpisode -> Triple(action.subjectId, action.episodeId, action.initialPositionMillis)
            is SyncAction.PopThenPushEpisode -> Triple(action.subjectId, action.episodeId, action.initialPositionMillis)
            is SyncAction.SwitchEpisodeInPlace, is SyncAction.SeekOnly -> return null
        }
        return AniWatchTogetherNavigation(
            subjectId = subjectId,
            episodeId = episodeId,
            positionMillis = position,
            subjectName = subjectName.orEmpty(),
            episodeSort = episodeSort.orEmpty(),
        )
    }

    private companion object {
        const val BUFFERING_DEBOUNCE_MILLIS = 2_000L
    }
}

internal fun resyncMessage(deltaMillis: Long): String {
    val seconds = (abs(deltaMillis) / 1000.0).roundToLong()
    return when {
        seconds == 0L -> "已与房主同步"
        deltaMillis > 0 -> "已与房主同步 (快进 $seconds 秒)"
        else -> "已与房主同步 (后退 $seconds 秒)"
    }
}

internal fun WatchTogetherJoinFailure.describe(): String = when (this) {
    WatchTogetherJoinFailure.WRONG_PASSWORD -> "密码错误"
    WatchTogetherJoinFailure.ROOM_FULL -> "房间已满"
    WatchTogetherJoinFailure.ROOM_CLOSED -> "房间已关闭"
    WatchTogetherJoinFailure.INVALID_NAME -> "房间名不合法"
    WatchTogetherJoinFailure.INVALID_PASSWORD -> "密码不合法"
    WatchTogetherJoinFailure.RATE_LIMITED -> "操作太频繁, 请稍后再试"
    WatchTogetherJoinFailure.TEMPORARY -> "网络错误, 请稍后再试"
}

internal fun RoomSession.toAniRoom(
    snapshot: AniWatchTogetherRoomSnapshot,
    following: Boolean,
    connection: WatchTogetherConnectionState,
): AniWatchTogetherRoom = AniWatchTogetherRoom(
    status = AniWatchTogetherStatus.IN_ROOM,
    roomName = roomName,
    isHost = isHost,
    following = following,
    connection = when (connection) {
        WatchTogetherConnectionState.ConnectedSse -> AniWatchTogetherConnection.CONNECTED
        WatchTogetherConnectionState.Reconnecting -> AniWatchTogetherConnection.RECONNECTING
        WatchTogetherConnectionState.DegradedPolling -> AniWatchTogetherConnection.POLLING
    },
    members = snapshot.members
        .sortedWith(compareByDescending<AniWatchTogetherMember> { it.isHost }.thenBy { it.nickname })
        .map { it.toAniMember() },
    hostWatching = snapshot.playback?.info?.toAniWatching(),
)

internal fun AniWatchTogetherMember.toAniMember(): AniWatchTogetherMemberInfo = AniWatchTogetherMemberInfo(
    userId = userId,
    nickname = nickname,
    avatarUrl = avatarUrl.orEmpty(),
    isHost = isHost,
    following = following,
    online = state != AniWatchTogetherMemberState.DISCONNECTED,
    watching = watching?.toAniWatching(),
)

internal fun AniWatchTogetherWatchingInfo.toAniWatching(): AniWatchTogetherWatching = AniWatchTogetherWatching(
    subjectId = subjectId,
    episodeId = episodeId,
    subjectName = subjectName,
    episodeSort = episodeSort,
    episodeName = episodeName,
    paused = paused,
)

enum class AniWatchTogetherStatus {
    /** 未开启或未登录 */
    DISABLED,
    IDLE,
    JOINING,
    IN_ROOM,
}

enum class AniWatchTogetherConnection {
    NONE,
    CONNECTED,
    RECONNECTING,
    POLLING,
}

data class AniWatchTogetherRoom(
    val status: AniWatchTogetherStatus,
    val roomName: String,
    val isHost: Boolean,
    val following: Boolean,
    val connection: AniWatchTogetherConnection,
    val members: List<AniWatchTogetherMemberInfo>,
    /** 房主正在播放的剧集; 房主不在播放器中时为 `null`. */
    val hostWatching: AniWatchTogetherWatching?,
) {
    internal companion object {
        fun inactive(status: AniWatchTogetherStatus) = AniWatchTogetherRoom(
            status = status,
            roomName = "",
            isHost = false,
            following = false,
            connection = AniWatchTogetherConnection.NONE,
            members = emptyList(),
            hostWatching = null,
        )
    }
}

data class AniWatchTogetherMemberInfo(
    val userId: String,
    val nickname: String,
    val avatarUrl: String,
    val isHost: Boolean,
    val following: Boolean,
    val online: Boolean,
    val watching: AniWatchTogetherWatching?,
)

data class AniWatchTogetherWatching(
    val subjectId: Int,
    val episodeId: Int,
    val subjectName: String,
    val episodeSort: String,
    val episodeName: String,
    val paused: Boolean,
)

/** 房主正在看其他条目, 需要打开对应的播放页. */
data class AniWatchTogetherNavigation(
    val subjectId: Int,
    val episodeId: Int,
    val positionMillis: Long,
    val subjectName: String,
    val episodeSort: String,
)

enum class AniPlaybackDirectiveKind {
    /** 同步位置, 速度与播放/暂停 */
    SYNC,

    /** 切换到同一条目的另一集 */
    SWITCH_EPISODE,
}

/**
 * 播放器应用的同步指令. [positionMillis] 是回调时刻房主的推算位置.
 * [forceSeek] 为 `true` 时总是跳转, 否则只在与本地相差超过 3 秒时跳转.
 */
data class AniPlaybackDirective(
    val kind: AniPlaybackDirectiveKind,
    val subjectId: Int,
    val episodeId: Int,
    val positionMillis: Long,
    val paused: Boolean,
    val playbackRate: Float,
    val forceSeek: Boolean,
)

interface AniWatchTogetherRoomListener {
    fun onRoom(room: AniWatchTogetherRoom)
}

interface AniWatchTogetherEventListener {
    fun onNavigate(navigation: AniWatchTogetherNavigation)
    fun onMessage(message: String)
}

interface AniWatchTogetherDirectiveListener {
    fun onDirective(directive: AniPlaybackDirective)
}
