/*
 * Copyright (C) 2026 OpenAni and contributors.
 * Use of this source code is governed by the GNU AGPLv3 license.
 */

package me.him188.ani.app.ui.adaptive.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTopPositionInRootIsEqualTo
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals
import me.him188.ani.app.data.models.preference.ThemeSettings
import me.him188.ani.app.ui.foundation.ProvideCompositionLocalsForPreview
import me.him188.ani.app.ui.foundation.theme.LocalAppChromeOverlayInsets
import me.him188.ani.app.ui.foundation.theme.LocalThemeSettings
import me.him188.ani.app.ui.framework.runAniComposeUiTest

class IosNavigationBarTest {
    @Test
    fun `content clears the floating bar when transparency is disabled`() = runAniComposeUiTest {
        setContent {
            ProvideCompositionLocalsForPreview {
                CompositionLocalProvider(LocalThemeSettings provides ThemeSettings(enableFrostedGlassEffect = false)) {
                    Box(Modifier.size(320.dp, 640.dp)) {
                        AniNavigationSuiteLayout(
                            layoutType = NavigationSuiteType.NavigationBar,
                            navigationSuite = {
                                Box(Modifier.fillMaxWidth().height(80.dp).testTag("bar"))
                            },
                        ) {
                            Box(Modifier.fillMaxSize().padding(LocalAppChromeOverlayInsets.current.asPaddingValues())) {
                                Box(Modifier.align(Alignment.BottomStart).size(20.dp).testTag("last-item"))
                            }
                        }
                    }
                }
            }
        }
        onNodeWithTag("bar").assertTopPositionInRootIsEqualTo(560.dp)
        onNodeWithTag("last-item").assertTopPositionInRootIsEqualTo(540.dp)
    }

    @Test
    fun `selecting a tab navigates once and reselecting scrolls without navigating`() = runAniComposeUiTest {
        var selected by mutableStateOf(0)
        var navigationCount = 0
        var scrollCount = 0
        setContent {
            MaterialTheme {
                val provider by rememberStateOfItems {
                    listOf("发现", "资料库").forEachIndexed { index, title ->
                        item(
                            selected = selected == index,
                            onClick = { selected = index; navigationCount++ },
                            onReselect = { scrollCount++ },
                            icon = {},
                            label = { Text(title) },
                        )
                    }
                    item(
                        selected = false,
                        enabled = false,
                        onClick = { navigationCount++ },
                        icon = {},
                        label = { Text("不可用") },
                    )
                }
                IosNavigationBar(provider, glassActive = false, containerColor = MaterialTheme.colorScheme.surface)
            }
        }
        onNodeWithText("发现").assertIsSelected()
        onNodeWithText("资料库").performClick().assertIsSelected()
        runOnIdle { assertEquals(1, navigationCount); assertEquals(0, scrollCount) }
        onNodeWithText("资料库").performClick()
        runOnIdle { assertEquals(1, navigationCount); assertEquals(1, scrollCount) }
        onNodeWithText("不可用").assertIsNotEnabled()
    }
}
