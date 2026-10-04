# iOS 风格界面

界面采用简体中文默认语言与 iOS 26 的视觉惯例, 由 Compose Multiplatform 的共享组件呈现于 Android、iOS 和桌面端.

## 视觉与操作

- 分层的中性背景、系统蓝默认强调色、34sp 大标题与圆角设置分组, 支持浅色和深色主题.
- 底部标签栏以圆角胶囊悬浮于内容上方, 标签具有选中语义、按压反馈与平台触觉反馈. 重复点击当前标签返回页面顶部.
- 标签栏完整高度包含底部安全区域和悬浮间距, 通过 `LocalAppChromeOverlayInsets` 提供给滚动页面. 关闭玻璃效果后仍保留内容避让.
- 手机首页的搜索入口位于滚动内容顶部; 宽屏搜索入口位于工具栏. 两者使用现有搜索页面.
- 紧凑窗口使用水平进入与返回动画; 宽屏使用淡入淡出. 返回按钮具有中文辅助功能标签.
- 设置开关可以通过整行操作, 禁用时整行与开关都不可操作. 设置保持现有持久化与业务行为.

## 渲染与偏好

玻璃表面使用项目现有的 Haze 模糊渲染, 叠加半透明底色和边缘高光. 这是跨平台的 iOS 风格实现, 不使用 UIKit 的原生 Liquid Glass 折射 API. 在“设置 → 显示与外观”中可关闭玻璃效果.

新安装默认使用简体中文、蓝色强调色和玻璃效果. 显式保存的语言、主题色与玻璃开关继续遵循用户偏好. 语言仍可在通用设置中选择, 包括跟随系统.

## 验证

`IosNavigationBarTest` 验证标签选择、重复选择、禁用语义和不透明模式下的内容避让. `IosDesignSystemTest` 验证文字对比度、强调色保留和纯黑偏好. `SwitchItemTest` 验证禁用开关及其整行不可操作.

```shell
./gradlew :app:shared:compileKotlinDesktop :app:shared:ui-adaptive:desktopTest :app:shared:ui-foundation:desktopTest :app:shared:app-lang:desktopTest :app:shared:ui-settings:desktopTest
```

iOS 的编译、手势和系统安全区域验证需要 macOS 与 Xcode. 在 `local.properties` 中设置 `ani.enable.ios=true` 与 `ani.build.framework=true`, 然后使用 `app/ios/Animeko` 项目运行. 请在真机或模拟器检查标签栏、键盘、返回操作、深色模式和较大辅助功能字号.
