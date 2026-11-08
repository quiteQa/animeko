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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import me.him188.ani.app.data.models.danmaku.DanmakuRegexFilter
import me.him188.ani.app.data.models.preference.HlsAdFilteringMode
import me.him188.ani.app.data.models.preference.NsfwMode
import me.him188.ani.app.data.repository.player.DanmakuRegexFilterRepository
import me.him188.ani.app.data.repository.user.SettingsRepository
import me.him188.ani.app.domain.media.fetch.MediaSourceManager
import me.him188.ani.danmaku.ui.DanmakuTextConversion
import me.him188.ani.datasources.api.source.MediaSourceKind
import org.koin.core.Koin
import kotlin.coroutines.CoroutineContext
import kotlin.uuid.ExperimentalUuidApi
import kotlin.uuid.Uuid

/**
 * iOS 客户端的设置. 读写的都是上游 [SettingsRepository] 中的同一份设置, 与其他平台的语义相同.
 */
class AniSettingsStore internal constructor(
    koin: Koin,
    private val scope: CoroutineScope,
    private val callbackContext: CoroutineContext,
) {
    private val settings: SettingsRepository = koin.get()
    private val regexFilters: DanmakuRegexFilterRepository = koin.get()
    private val mediaSourceManager: MediaSourceManager = koin.get()

    fun observeSettings(listener: AniSettingsListener): AniSubscription =
        scope.launchObserver(callbackContext, settingsFlow()) { listener.onSettings(it) }

    private fun settingsFlow(): Flow<AniSettings> = combine(
        settings.mediaSelectorSettings.flow,
        settings.videoScaffoldConfig.flow,
        combine(settings.danmakuEnabled.flow, settings.danmakuConfig.flow) { enabled, config -> enabled to config },
        settings.uiSettings.flow,
        settings.pikpakConfig.flow,
    ) { selector, video, (danmakuEnabled, danmaku), ui, pikpak ->
        AniSettings(
            preferWebSources = selector.preferKind == MediaSourceKind.WEB,
            fastSelectWeb = selector.fastSelectWebKind,
            autoEnableLastSelected = selector.autoEnableLastSelected,
            hlsAdFiltering = video.effectiveHlsAdFilteringMode.name,
            autoMarkDone = video.autoMarkDone,
            danmakuEnabled = danmakuEnabled,
            danmakuShowTop = danmaku.enableTop,
            danmakuShowBottom = danmaku.enableBottom,
            danmakuShowFloating = danmaku.enableFloating,
            danmakuShowColor = danmaku.enableColor,
            danmakuTextConversion = danmaku.textConversion.name,
            nsfwMode = ui.searchSettings.nsfwMode.name,
            pikpakEnabled = pikpak.enabled,
            pikpakUsername = pikpak.username,
            autoSkipOpEd = video.autoSkipOpEd,
            opEdSkipSeconds = video.opEdSkipDuration.inWholeSeconds.toInt(),
            autoPlayNext = video.autoPlayNext,
        )
    }

    // region 选源与播放

    /** 优先选择在线 (WEB) 数据源; 关闭时不限制类型. */
    @Throws(Exception::class)
    suspend fun setPreferWebSources(value: Boolean) {
        settings.mediaSelectorSettings.update { copy(preferKind = if (value) MediaSourceKind.WEB else null) }
    }

    /** 在线数据源快速选择: 高阶级的源查询完成后立即选择, 不等待全部数据源. */
    @Throws(Exception::class)
    suspend fun setFastSelectWeb(value: Boolean) {
        settings.mediaSelectorSettings.update { copy(fastSelectWebKind = value) }
    }

    /** 自动启用上次使用的 (已禁用的) 数据源. */
    @Throws(Exception::class)
    suspend fun setAutoEnableLastSelected(value: Boolean) {
        settings.mediaSelectorSettings.update { copy(autoEnableLastSelected = value) }
    }

    /** @param mode `ALL`, `SMART` 或 `OFF`. */
    @Throws(Exception::class)
    suspend fun setHlsAdFiltering(mode: String) {
        val value = HlsAdFilteringMode.valueOf(mode)
        settings.videoScaffoldConfig.update { copy(hlsAdFilteringMode = value) }
    }

    /** 看到 90% 时自动标记看过. */
    @Throws(Exception::class)
    suspend fun setAutoMarkDone(value: Boolean) {
        settings.videoScaffoldConfig.update { copy(autoMarkDone = value) }
    }

    /** 根据服务器汇总的跳过点自动跳过 OP/ED. */
    @Throws(Exception::class)
    suspend fun setAutoSkipOpEd(value: Boolean) {
        settings.videoScaffoldConfig.update { copy(autoSkipOpEd = value) }
    }

    /** 播放结束后自动播放下一集. */
    @Throws(Exception::class)
    suspend fun setAutoPlayNext(value: Boolean) {
        settings.videoScaffoldConfig.update { copy(autoPlayNext = value) }
    }

    /** @param mode `HIDE`, `BLUR` 或 `DISPLAY`. */
    @Throws(Exception::class)
    suspend fun setNsfwMode(mode: String) {
        val value = NsfwMode.valueOf(mode)
        settings.uiSettings.update { copy(searchSettings = searchSettings.copy(nsfwMode = value)) }
    }

    // endregion

    // region 弹幕

    @Throws(Exception::class)
    suspend fun setDanmakuEnabled(value: Boolean) {
        settings.danmakuEnabled.set(value)
    }

    @Throws(Exception::class)
    suspend fun setDanmakuVisibility(top: Boolean, bottom: Boolean, floating: Boolean, color: Boolean) {
        settings.danmakuConfig.update {
            copy(enableTop = top, enableBottom = bottom, enableFloating = floating, enableColor = color)
        }
    }

    /** @param target `ORIGINAL`, `SIMPLIFIED`, `TRADITIONAL`, `TAIWAN` 或 `HONG_KONG`. */
    @Throws(Exception::class)
    suspend fun setDanmakuTextConversion(target: String) {
        val value = DanmakuTextConversion.valueOf(target)
        settings.danmakuConfig.update { copy(textConversion = value) }
    }

    fun observeDanmakuFilters(listener: AniDanmakuFiltersListener): AniSubscription = scope.launchObserver(
        callbackContext,
        regexFilters.flow.map { list -> list.map { AniDanmakuFilter(it.id, it.name, it.regex, it.enabled) } },
    ) { listener.onFilters(it) }

    /**
     * 添加正则屏蔽词.
     *
     * @throws IllegalArgumentException [regex] 不是合法的正则表达式.
     */
    @OptIn(ExperimentalUuidApi::class)
    @Throws(Exception::class)
    suspend fun addDanmakuFilter(regex: String) {
        Regex(regex) // 校验
        regexFilters.add(DanmakuRegexFilter(id = Uuid.random().toString(), name = regex, regex = regex, enabled = true))
    }

    @Throws(Exception::class)
    suspend fun setDanmakuFilterEnabled(id: String, enabled: Boolean) {
        val filter = regexFilters.find(id) ?: return
        regexFilters.update(id, filter.copy(enabled = enabled))
    }

    @Throws(Exception::class)
    suspend fun removeDanmakuFilter(id: String) {
        val filter = regexFilters.find(id) ?: return
        regexFilters.remove(filter)
    }

    private suspend fun DanmakuRegexFilterRepository.find(id: String): DanmakuRegexFilter? =
        flow.first().firstOrNull { it.id == id }

    // endregion

    // region 数据源

    fun observeMediaSources(listener: AniMediaSourcesListener): AniSubscription = scope.launchObserver(
        callbackContext,
        mediaSourceManager.allInstances.map { list ->
            list.map {
                AniMediaSourceItem(
                    instanceId = it.instanceId,
                    mediaSourceId = it.mediaSourceId,
                    displayName = it.source.info.displayName,
                    kind = it.source.kind.name,
                    enabled = it.isEnabled,
                )
            }
        },
    ) { listener.onMediaSources(it) }

    @Throws(Exception::class)
    suspend fun setMediaSourceEnabled(instanceId: String, enabled: Boolean) {
        mediaSourceManager.setEnabled(instanceId, enabled)
    }

    // endregion

    // region PikPak

    /**
     * 设置 PikPak 云离线账号. iOS 没有本地 BT 引擎, 配置后 BT 资源经 PikPak 播放.
     * 切换账号时清除旧账号的登录凭据.
     */
    @Throws(Exception::class)
    suspend fun setPikPak(enabled: Boolean, username: String, password: String) {
        settings.pikpakConfig.update {
            val sameAccount = this.username == username
            copy(
                enabled = enabled,
                username = username,
                password = password.ifEmpty { if (sameAccount) this.password else "" },
                refreshToken = if (sameAccount) refreshToken else "",
            )
        }
    }

    // endregion
}

interface AniSettingsListener {
    fun onSettings(settings: AniSettings)
}

interface AniDanmakuFiltersListener {
    fun onFilters(filters: List<AniDanmakuFilter>)
}

interface AniMediaSourcesListener {
    fun onMediaSources(sources: List<AniMediaSourceItem>)
}
