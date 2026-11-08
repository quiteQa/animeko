# iOS 原生客户端 (SwiftUI)

保留 Animeko 的 Kotlin 数据层, 界面用 SwiftUI 重写的 iOS 客户端. 只面向 iOS, 不向上游提交.

```
app/ios-native/
├── core/            Kotlin facade, Gradle 模块 :app:ios-native:core, 产出 AniCore.framework
│   └── src/
│       ├── commonMain/   AniCore, AniEpisodeSession, 值类型与映射 (桌面端可编译与测试)
│       ├── iosMain/      startAniCore(): 启动 Koin, 不创建任何 Compose 界面
│       └── commonTest/
└── App/             SwiftUI App (XcodeGen + CocoaPods)
    ├── project.yml
    ├── Podfile
    ├── Sources/
    │   ├── Core/          AniCore 的 Swift 适配 (observe* → AsyncStream)
    │   └── Features/      Search, Subject, Player, Danmaku
    └── Tests/             不依赖 AniCore 的纯 Swift 单元测试
```

对上游文件的修改只有 `settings.gradle.kts` 中的一行 `includeProject`.

## 分层

```
SwiftUI 视图 ── @Observable 模型 ── AVPlayer / 弹幕 CALayer      (Swift, 全部新写)
                    │
             AniCore.framework                                    (唯一边界)
                    │
   AniCore / AniEpisodeSession (Kotlin facade, 新写, 薄)
                    │
 app-data · datasource · danmaku · application 的 Koin 装配        (上游, 不改)
```

- Swift 只调用 `AniCore` 与 `AniEpisodeSession`. 它们只暴露 `Ani*` 值类型 (String / Int / Long / List / Map),
  不暴露任何 app-data 类型; 上游数据模型变动时只需改 `core/src/commonMain/kotlin/Mappers.kt`.
- `suspend` 函数在 Swift 中是 `async throws`. `Flow` 不直接跨边界: facade 提供 `observe*(listener)`,
  回调在主线程触发, Swift 侧用 `AsyncStream` 包装 (`Sources/Core/CoreBridge.swift`).
- 界面状态全部归 Swift `@Observable`. Kotlin 只负责查询, 选择与解析, 不持有屏幕状态.
- Swift 持有 `AVPlayer`. `AniEpisodeSession.resolveSelected()` 返回可播放 URL, 请求头与外挂字幕, Swift 用它创建
  `AVURLAsset`. 播放进度从不跨边界.
- 弹幕一次性取回整集 (`fetchDanmaku()`), 由 Swift 的 `DanmakuOverlayView` 按播放器时间逐帧排布, 也不跨边界.

## 一集的播放流程

`AniEpisodeSession` 依次调用上游的用例, 选源规则与其他平台一致:

1. `GetSubjectEpisodeInfoBundleFlowUseCase`: 读取条目与剧集
2. `CreateMediaFetchSelectBundleFlowUseCase`: 创建 `MediaFetchSession` 与 `MediaSelector`, 并发查询所有启用的数据源
   (会话持续收集 `cumulativeResults`, 否则查询会中断)
3. `MediaSelectorAutoSelectUseCase`: 按偏好, 数据源阶级与快速选择超时自动选择
4. `MediaResolver` (Koin 中 `getIosModules` 的链): 网页资源由 `IosWebMediaResolver` 在后台 `WKWebView` 中拦截视频地址,
   接口资源由 `ApiVideoMediaResolver` 签发, 直链由 `HttpStreamingMediaResolver` 处理
5. `MediaDataProvider.open()` 得到 `UriMediaData`, 映射为 `AniPlayable` 交给 Swift

## P0 验证结论

| 问题 | 结论 | 依据 |
| --- | --- | --- |
| `app-data` 能否脱离 Compose 编译 | **不能**, 切割线改为 API 级 | 见下文 |
| 自动选源逻辑在哪一层 | 在 `app-data`, 可整体复用 | `MediaSelector`, `DefaultMediaSelector`, `MediaSelectorAutoSelectUseCase`, `MediaAutoSelector`, `ReplayBrowseMemoryUseCase` 都在 `app/shared/app-data/.../domain/media/selector/`; `ui-mediaselect` 只有展示状态 |
| `Flow` 跨边界开销 | 未测 (需要真机), 设计上规避 | 高频数据 (播放进度, 弹幕逐帧位置) 不跨边界; 跨边界的只有候选列表, 选中项与查询进度这类低频更新 |

### app-data 与 Compose

- `app-data` 与 `app-platform` 使用 `ani.kmp-compose` 插件, 以 `api` 依赖 compose-foundation / ui / material3.
- `app-data` 的 `commonMain` 有 77 个文件引用 `androidx.compose`, 大多是 `runtime` 的 `@Stable` / `@Immutable` / `State`;
  `UISettings`, `ThemeSettings`, `DanmakuConfigSerializer`, `WindowStateRepository`, `InteractiveSolveDialog` 引用了 ui / foundation / material;
  `MediaResolver` 接口本身带一个 `@Composable fun ComposeContent()`.
- `app-data` 以 `api` 依赖 `danmaku-ui-config`, 后者也是 Compose 模块.
- Koin 装配 (`getCommonKoinModule`, 660 行) 位于 `:app:shared:application`, 该模块依赖 `ui-foundation` 与整个 `:app:shared`.

要做到"模块级脱 Compose", 必须改上游的 `app-data`, `app-platform` 与 Koin 装配, 这与"上游文件修改只限两处"冲突,
每次 rebase 都会付出代价. 因此采用 **API 级切割**: `AniCore.framework` 照常链接上游 (含 Compose 与 `application`) 的 klib,
但 `transitiveExport = false`, Swift 只能看到 facade. 好处是上游源码零改动, Koin 装配零复制; 代价是二进制体积,
需要在 macOS 上实测 (Kotlin/Native 链接时会去掉未被引用的代码, 但 Koin 模块会引用大量类).

### 其他发现

- iOS 的网页资源解析 `IosWebMediaResolver` 使用后台 `WKWebView`, `ComposeContent()` 为空实现, 不需要 Compose 宿主.
- `torrent:anitorrent` 的公共代码会为 iOS 编译 (`ani.kmp-library` 在 `ani.enable.ios=true` 时添加 iOS target), 但原生引擎只有
  JVM 版本, iOS 上没有本地 BT 引擎. iOS 的 `TorrentManager` 已经接入 `PikPakEngine`.
- 上游 iOS framework 依赖 Sentry 与 onnxruntime 两个 pod (验证码识别). facade 链接 `application` 的 klib, 因此同样需要这两个 pod,
  集成方式沿用上游的 CocoaPods, 而不是单独的 XCFramework.

## 构建

Kotlin facade 的公共代码可以在任何平台编译和测试:

```shell
./gradlew :app:ios-native:core:compileKotlinDesktop
./gradlew :app:ios-native:core:desktopTest
```

iOS App 需要 macOS, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) 与 CocoaPods.
与上游 iOS 构建相同, 先在 `local.properties` 中启用 iOS (Xcode 构建阶段调用 Gradle 时也读取这里):

```properties
ani.enable.ios=true
ani.build.framework=true
```

```shell
# 1. 准备 FFmpeg 运行时 (被 AniCore 链接, 并随 App 嵌入)
./gradlew :utils:http-downloader:extractMediampFfmpegAppleRuntime

# 2. 生成 AniCore 的 podspec
./gradlew :app:ios-native:core:podspec

# 3. 生成 Xcode 工程并安装 pod
cd app/ios-native/App
xcodegen generate
pod install
open AnimekoNative.xcworkspace
```

Xcode 构建时, CocoaPods 的脚本阶段会调用 Gradle 编译并链接 AniCore.

## 已知差异与待办

- 未接入上游的 HLS 本地代理 (`HlsPlaybackPreparer`, 用于去广告与分片预取). 依赖它的网页源在 iOS 原生客户端上可能卡顿或带广告.
- 弹幕未做简繁转换与屏蔽词过滤 (上游在 `DanmakuLoader` / 播放页里完成).
- 未处理 OP/ED 跳过, 播放进度记忆, 剧集收藏同步 (P2).
- 选源面板是简版列表; 自动匹配 / 手动查找 / BT 三种模式在 P2 实现.
