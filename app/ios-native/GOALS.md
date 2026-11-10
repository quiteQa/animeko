# iOS 原生客户端目标

本文是 `app/ios-native` 的目标与已定决策. 当前实现见 [README](README.md); 两者不一致的地方列在文末的
[变更对比](#变更对比), 以本文为准, 实现按里程碑逐步向本文靠拢.

## 定位

- 只供自己使用: 不分发, 不开源, 不向上游提交. 因此没有 AGPL 的分发义务.
- 保留上游 Kotlin 内核 (数据源, 弹幕接口, `app-data` 仓库层), UI 与 ViewModel 全部用 SwiftUI 重写.

## 首版范围

| 功能 | 说明 |
| --- | --- |
| 追番列表, 条目详情, 搜索 | |
| 在线源播放 | 网页 / 接口 / 直链数据源 |
| Jellyfin 播放 | 上游 `datasource/jellyfin` |
| 弹幕 | 只读, 不发送 |
| 进度回写 Bangumi | 观看进度与看过标记 |
| BT | 首版即包含, 见决策 2 |
| 画中画, AirPlay | 首版即包含, 见决策 4 |

## 已定决策

1. **播放内核: MPV** (libmpv, 例如 [MPVKit](https://github.com/mpvkit/MPVKit)), 不用 AVPlayer.
   风险: 包体积变大; MPVKit 自称更新不频繁, Metal 输出是补丁版本; 默认是 LGPL 构建.
2. **首版就做 BT.** 上游 `anitorrent` 只带桌面端 libtorrent, 没有 iOS 目标. 需要自己把 libtorrent (依赖 Boost, OpenSSL)
   交叉编译到 iOS, 尽量复用 `anitorrent` 的上层逻辑. iOS 会挂起后台应用, BT 只能在前台下载和做种.
3. **最低系统 iOS 26.** 不为旧系统做 Liquid Glass 降级.
4. **画中画与 AirPlay 首版就做.** 两者都是围绕 AVPlayer 设计的:
   - 画中画需要把 MPV 的画面交给系统接管;
   - AirPlay 不能直接投送 MKV 或 BT 流. 在线源可能改用 AVPlayer 投送, 其余依靠屏幕镜像.

   列为风险, 在 M2 验证可行性.
5. **不分发, 不开源** (见定位).
6. **Kotlin 与 Swift 桥接用 [SKIE](https://skie.touchlab.co/).** `Flow` 在 Swift 中可以 `for await`, `suspend` 变为 Swift `async`.
   代价: SKIE 绑定特定的 Kotlin 版本, 升级 Kotlin 前要等 SKIE 支持.
7. **上游版本:** 开工时锁定上游最新正式版; 之后只在需要新功能时升级, 不按固定周期跟进.
8. **签名用免费 Apple ID.**
   - 安装包 7 天过期, 需要重签;
   - 每台设备最多 3 个此类应用;
   - 远程推送与 iCloud 不可用, 更新提醒只能用本地通知;
   - 后台播放与画中画可用.

## 里程碑

| 里程碑 | 内容 |
| --- | --- |
| M0 | 验证 libtorrent 能交叉编译到 iOS 并运行 |
| M1 | 未定 |
| M2 | 验证 MPV 下画中画与 AirPlay 的可行性 |
| M3 | BT 边下边播 |

## 变更对比

逐条对比本文决策与当前实现 (README 及代码, 截至提交 `48f9aa9`). "冲突" 以本文为准, 需要在后续里程碑中修改实现.

| 决策 | 对比 | 当前实现 | 需要的改动 |
| --- | --- | --- | --- |
| 1. MPV 内核 | **冲突** | Swift 持有 `AVPlayer`; `AniEpisodeSession.resolveSelected()` 返回 URL 交给 `AVURLAsset`. 画质增强 (Metal), 播放信息, 截图 (`AVPlayerItemVideoOutput`), 倍速, 一起看同步都建立在 AVPlayer 上 | 换成 libmpv. 上述功能需要在 MPV 上重新实现; MPV 自带解码, 可以播放 AVPlayer 不支持的 MKV 等容器 |
| 2. 首版做 BT | **冲突** | 不支持 BT: 上游 `MediaSourceManager` 在 iOS 上排除 BT 数据源, iOS 没有本地 BT 引擎; README 也写明不提供 BT 列表页 | 交叉编译 libtorrent; 修改上游 `MediaSourceManager` 中排除 iOS 的那一行 (与"上游只改 `settings.gradle.kts` 一行"的约定冲突, 需要接受额外的上游改动) |
| 3. 仅 iOS 26 | 一致 | `project.yml` 的部署目标是 iOS 26.0, 界面直接使用 Liquid Glass, 没有降级 | 无 |
| 4. 画中画与 AirPlay | 部分一致, 新增风险 | 画中画已实现, 基于 `AVPlayerLayer` 的 `AVPictureInPictureController`; AirPlay 没有专门处理 (AVPlayer 默认可投送) | 换到 MPV 后画中画需要重新实现 (见决策 4), AirPlay 方案在 M2 验证 |
| 5. 不分发不开源 | 一致 | README: "只面向 iOS, 不向上游提交" | 补充 "不分发, 不开源" 的说明 (本文) |
| 6. SKIE 桥接 | **冲突** | 未用 SKIE: facade 提供 `observe*(listener)`, Swift 在 `CoreBridge.swift` 中用 `AsyncStream` 包装; `suspend` 已由 Kotlin/Native 导出为 `async throws` | 引入 SKIE, 删除 listener 与 `CoreBridge.swift` 的手写适配. 当前 Kotlin 版本 2.4.10, 需要确认 SKIE 是否支持 |
| 7. 锁定上游正式版 | **冲突** | 分支基于上游 `main`, 位于 `v6.4.0` 之后 16 个提交, 不是正式版 | 改为基于最新正式版 (目前是 `v6.4.0`), 之后按需升级 |
| 8. 免费 Apple ID 签名 | 一致 | CI 产出未签名 IPA, 由 SideStore / AltStore 用自己的 Apple ID 重签 | 补充 7 天过期, 3 个应用上限, 推送与 iCloud 不可用的限制 (本文) |
| 首版范围: 在线源 | 一致 | 已实现, 选源与解析复用上游 | 换内核后回归 |
| 首版范围: Jellyfin | 新增 | 没有专门适配, 也未验证 Jellyfin 源能否在 iOS 上查询和播放 | M1 之前验证 |
| 首版范围: 只读弹幕 | 一致 | 弹幕只读, 不能发送 | 无 |
| 首版范围: 进度回写 Bangumi | 一致 | 每 5 秒及暂停 / 退出时保存进度, 看到 90% 标记看过 | 换内核后回归 |
| 首版范围之外的已有功能 | 范围外 | 已实现一起看, 剧集评论 (含发表), 缓存管理, 手动查找, OP/ED 跳过, 画质增强等 | 不删除; 换到 MPV 时作为回归项, 不阻塞首版 |

改动的原因: 以上决策由用户在规划中确定 (MPV 为了容器与解码覆盖面, BT 与画中画 / AirPlay 是首版必需的功能,
SKIE 为了去掉手写桥接, 锁定正式版为了减少跟进上游的成本). 本文只记录决策与差异, 不改变当前代码.
