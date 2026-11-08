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
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.CoroutineContext

/**
 * 收集 [flow], 在 [callbackContext] 上把去重后的值交给 [onValue]. 上游抛出的异常交给 [onError], 之后不再回调.
 */
internal fun <T> CoroutineScope.launchObserver(
    callbackContext: CoroutineContext,
    flow: Flow<T>,
    onError: (Throwable) -> Unit = {},
    onValue: (T) -> Unit,
): AniSubscription {
    val job = launch {
        flow.distinctUntilChanged()
            .catch { e -> withContext(callbackContext) { onError(e) } }
            .collect { value -> withContext(callbackContext) { onValue(value) } }
    }
    return AniSubscription(job)
}
