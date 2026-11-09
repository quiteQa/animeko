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
    │   ├── Common/        跨页面的文案与格式
    │   └── Features/      Collection, Explore, Search, Subject, Player, Danmaku,
    │                      Comments, Downloads, Settings, Account
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
3. 与上游 `AutoSelectExtension` 相同的顺序: 本集有本地缓存则选缓存; 否则按手动查找的浏览记忆回放
   (`ReplayBrowseMemoryUseCase`); 都没有时由 `MediaSelectorAutoSelectUseCase` 按偏好, 数据源阶级与快速选择超时自动选择.
   在选源面板手动换源会删除本条目的浏览记忆
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
  JVM 版本, iOS 上没有本地 BT 引擎.
- 上游在 iOS 上不查询 BT 数据源: `MediaSourceManager` 以 `MediaFetcherConfig(currentPlatform() != Platform.Ios)`
  创建查询器, 查询会话直接排除 BT 源. 因此 iOS 上没有 BT 候选, PikPak 云离线也无从使用;
  本客户端不提供 BT 列表页与 PikPak 设置, 数据源列表也不显示 BT 源. 要支持 BT 需要修改上游的这一行.
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

## 功能

| 页面 | 内容 | 复用的上游逻辑 |
| --- | --- | --- |
| 追番 | 按收藏类型列出, 续看进度, 一键播放下一集, 下拉刷新 | `SubjectCollectionRepository` 的最近更新收藏与续看状态 |
| 搜索 | 系统搜索栏, 分页 | `AniSubjectSearchService` |
| 条目详情 | 收藏状态菜单, 继续观看, 剧集左滑 / 长按标记看过 | `SetSubjectCollectionTypeOrDeleteUseCase`, `EpisodeCollectionRepository` |
| 播放 | 自动选源, 续播上次位置, 每 5 秒及暂停/退出时保存进度, 看到 90% 自动标记看过, 画中画, HLS 去广告 | 选源用例, `MediaResolver`, `EpisodePlayHistoryRepository`, `HlsPlaybackPreparer`, 标记规则同 `MarkAsWatchedExtension` |
| 播放页 | 布局同上游竖屏剧集页: 视频下方「详情 / 评论」, 详情含番剧名与收藏, 数据源摘要, 弹幕摘要, 横向剧集列表 (长按标记看过) 与全部剧集网格; 全屏时 iPhone 自动横屏 | 上游 `EpisodeDetails`, `MediaSelectorSummaryBanner`, `EpisodeListSection` |
| 画质增强 / 播放信息 / 外部链接 | 更多选项菜单中切换画质增强 (性能优先 / 最高质量 / 关闭, 默认档位可在设置中修改), 显示播放信息 (分辨率, 帧率, 编码, 码率, 实时输入, 丢帧), 复制或访问视频流链接与数据源页面 | 上游 `app/ios` 的 `EnhancedPlayerView` (Metal), `PlayerStatsOverlay`, `ShareEpisodeDropdown` 的行为 |
| OP/ED 与下一集 | 按服务器汇总的跳过点自动跳过 (开始前 5 秒提示, 可取消), 手动跳过按钮 (上报跳过点), 播完自动播放下一集, 下一集按钮; 在同一播放页内切换剧集 | `AutoSkipRepository`, 片段与跳过规则同上游 `PlayerSkipOpEdState`, 下一集规则同 `SwitchNextEpisodeExtension` |
| 选源面板 | 全部 / 符合偏好的资源, 字幕组 · 分辨率 · 字幕 · 数据源四维偏好, 每个数据源的查询状态与重试 | `MediaSelector` 的偏好项, `MediaFetchSession` |
| 手动查找 | 选源 (下拉), 关键字搜索 (按源缓存结果), 打开条目选线路与剧集 (预选当前集), "记住选择" 开关; 记住时之后每集按线路位置自动选择 | 数据源浏览协议, `preselectedBrowseEpisodeIndex`, `ManualBrowseMemoryRepository`, `ReplayBrowseMemoryUseCase` |
| 弹幕 | 清理文本, 简繁转换, 正则屏蔽词, 按轨道排布 | `DanmakuRepository`, `DanmakuTextConverter`, `TimeBasedDanmakuSession.filterList` |
| 我的 | Bangumi 授权登录 / 绑定, 退出登录 | `OAuthConfigurator`, `BangumiOAuthClient` |
| 探索 | 热门条目, 前后 7 天的放送时间表 | `TrendsRepository`, `GetAnimeScheduleFlowUseCase` |
| 评论 | 条目评价, 剧集评论 (Ani 与 Bangumi 合并), 登录后发表剧集评论; BBCode 转为纯文本显示 | `BangumiCommentService`, `AniEpisodeCommentService`, `utils:bbcode` |
| 缓存管理 | 播放页一键缓存当前资源, 按条目分组的缓存列表, 暂停 / 继续 / 删除; 缓存好的剧集播放时自动优先 | `AddDownloadUseCase`, `MediaDownloadManager`, `DownloadOperations` |
| 设置 | 选源偏好, 数据源开关, HLS 去广告, 自动标记看过, 弹幕类型 / 彩色 / 文字转换 / 屏蔽词, NSFW 显示方式 | `SettingsRepository`, `MediaSourceManager`, `DanmakuRegexFilterRepository` |

设置读写的是上游 `SettingsRepository` 中的同一份数据, 语义与其他平台一致 (例如关闭 "自动标记看过" 后,
播放会话不再标记).

登录流程: Kotlin 侧向服务器申请授权链接, Swift 在 App 内 Safari 中打开; 用户授权后 Kotlin 轮询到结果并写入会话.
关闭授权页即取消本次登录.

## 已知差异与待办

- 自动跳过 OP/ED 只用服务器汇总的跳过点, 不读取视频文件自带的章节; 也不为跳转目标预缓存 (上游经 HLS 代理预取分片),
  跳过后可能需要短暂缓冲.
- 没有 BT 列表页 (原因见 P0 的其他发现). 需要验证码的数据源在 iOS 上无法交互验证, 手动查找会提示不支持 (上游 iOS 同样不支持).
- 弹幕没有按来源的开关与时间偏移, 不能发送弹幕.
- 评论只显示纯文本 (图片与表情以占位文字显示), 不支持回复, 点赞与举报.
- 缓存只能从播放页逐集添加, 没有上游的批量选集下载.
- 设置只覆盖上表列出的项; 数据源订阅的增删, 代理, 主题等仍需在其他平台的客户端里修改.
- 时间表跨过午夜不会自动切换 "今天", 重新进入页面即可.
