/*
 * Copyright (C) 2024-2025 OpenAni and contributors.
 *
 * 此源代码的使用受 GNU AFFERO GENERAL PUBLIC LICENSE version 3 许可证的约束, 可以在以下链接找到该许可证.
 * Use of this source code is governed by the GNU AGPLv3 license, which can be found at the following link.
 *
 * https://github.com/open-ani/ani/blob/main/LICENSE
 */

package me.him188.ani.app.ui.settings.tabs.app

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.text.intl.Locale
import me.him188.ani.app.data.models.preference.PlayerKernelConfig
import me.him188.ani.app.data.models.preference.UISettings
import me.him188.ani.app.data.models.preference.VideoScaffoldConfig
import me.him188.ani.app.ui.lang.Lang
import me.him188.ani.app.ui.lang.SupportedLocales
import me.him188.ani.app.ui.lang.renderLocale
import me.him188.ani.app.ui.lang.settings_app_language
import me.him188.ani.app.ui.settings.framework.SettingsState
import me.him188.ani.app.ui.settings.framework.components.DropdownItem
import me.him188.ani.app.ui.settings.framework.components.SettingsScope
import org.jetbrains.compose.resources.stringResource

@Composable
internal actual fun SettingsScope.AppSettingsTabPlatform() {
}

@Suppress("UNUSED_PARAMETER")
@Composable
internal actual fun SettingsScope.PlayerGroupPlatform(
    videoScaffoldConfig: SettingsState<VideoScaffoldConfig>,
    playerKernelConfig: SettingsState<PlayerKernelConfig>,
) {
    // NOOP
}

@Composable
internal actual fun SettingsScope.LanguageSettingsPlatform(
    state: SettingsState<UISettings>,
) {
    val uiSettings by state
    DropdownItem(
        selected = { uiSettings.appLanguage },
        values = { listOf<Locale?>(null) + SupportedLocales },
        itemText = { Text(renderLocale(it)) },
        onSelect = { state.update(uiSettings.copy(appLanguage = it)) },
        title = { Text(stringResource(Lang.settings_app_language)) },
    )
}
