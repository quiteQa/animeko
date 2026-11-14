/*
 * Copyright (C) 2024-2026 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.iosnative.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

// 暴露给 Swift 的 Flow 由 SKIE 转为 `AsyncSequence`, Swift 用 `for await` 收集, 取消所在的 Task 即停止收集.
// SKIE 的序列不抛出错误, 因此 Flow 在这里吞掉或转换上游异常.

/** 去重; 上游抛出异常时结束, 不传给 Swift. */
internal fun <T> Flow<T>.forSwift(): Flow<T> = distinctUntilChanged().catch { }

/** 去重; 上游抛出异常时发出 [onError] 的结果再结束, 让 Swift 显示错误. */
internal fun <T, R> Flow<T>.forSwift(onValue: (T) -> R, onError: (String) -> R): Flow<R> =
    map(onValue).distinctUntilChanged().catch { emit(onError(it.message ?: it.toString())) }
