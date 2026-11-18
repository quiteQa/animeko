# 原生 iOS 验证与交付状态

本轮实现范围为在线源、Jellyfin、BT 边下边播与缓存、mpv SDR 画中画、手机端 AirPlay 视频供流及性能采样。4K HDR / Dolby Vision 全保真属于独立后续目标。

## 播放页交互验证

2026-11-18, 应用代码 `6216a59ba6406e397bbd97baadaac8640598e96c`:

- 方向、锁定与全屏状态由播放页统一管理; 退出全屏同步恢复内嵌视频、详情布局、触摸与状态栏, 播放会话保持连续。
- 视频左侧纵向拖动调亮度, 右侧调系统媒体音量; 手势避开按钮、进度条与边缘, 锁定时禁用。离开播放页恢复手势前的亮度, 包括窗口先拆除的情况。
- [纯 Swift 回归](https://github.com/quiteQa/animeko/actions/runs/44218080738): 30 项通过, 包括丢失横屏通知时的竖屏退出、连续 50 次切换、锁定、拖动方向与范围。
- [媒体 SDK 与集成测试](https://github.com/quiteQa/animeko/actions/runs/44218080810): 生产代码 SDK 检查及 8 项测试通过, 包括亮度恢复与系统音量滑块事件、禁用输出处理。
- [iPhone 模拟器交互回归](https://github.com/quiteQa/animeko/actions/runs/44220913419): 3 项通过, 覆盖横转竖恢复详情与播放操作、反复手动退出的布局与按钮, 以及左右手势、进度条与锁定。
- [完整 IPA 构建](https://github.com/quiteQa/animeko/actions/runs/44218080767): Kotlin facade 回归、原生引擎构建、App 归档、FFmpeg 链接检查和打包上传通过; [未签名 IPA](https://github.com/quiteQa/animeko/actions/runs/44218080767/artifacts/14391394051)安装前需签名。

模拟器交互测试复用生产视口、方向策略与手势层, 使用无网络的播放桩, 覆盖旋转后布局/点击、重复进出全屏、滑动与锁定。它不验证实际 mpv 解码、真机方向传感器或外部设备的物理音量。实际设备需复核竖屏恢复、页面滚动、后台与音频路由。

界面层级、风格统一与视觉优化方案见 [UI_REVIEW.md](UI_REVIEW.md)。

## 功能基线自动验证

2026-11-17, 代码提交 `1844b325826c7502ea00f67c42826a572c93453b`:

- [媒体 SDK 与集成测试](https://github.com/quiteQa/animeko/actions/runs/44026759915): Xcode 26 的生产 Swift/Objective-C 检查及 6 项模拟器测试通过, 覆盖 mpv 实际像素/缓冲池、HTTP Range/撤销、HLS 视频、带音频的 seek/转换、HDR 拒绝、VOD 暂停/倍速时钟。
- [原生 BT](https://github.com/quiteQa/animeko/actions/runs/44026759905): iOS 交叉编译与模拟器 P2P 回归通过, 包括分片/尾部读取、EOF、取消、并发缓存回收、暂停读取、重复打开、原始磁力的离线恢复和实际缓存文件删除。
- [纯 Swift 回归](https://github.com/quiteQa/animeko/actions/runs/44026759921): 24 项策略与生命周期回归通过。
- [完整 IPA 构建](https://github.com/quiteQa/animeko/actions/runs/44026759917): Kotlin facade 回归、原生依赖构建、App 归档和 FFmpeg 链接检查通过; [未签名 IPA](https://github.com/quiteQa/animeko/actions/runs/44026759917/artifacts/14306717781)已打包上传, 安装前需签名。

上述结果不替代目标 iPhone 与 AirPlay 接收器的实测。

## 实现与验证边界

| 能力 | 生产实现 | 验证边界 |
| --- | --- | --- |
| 在线播放可靠性 | 串行原生队列、任务代次、进度合并、完整请求头、音频中断、弹幕过滤 | 纯 Swift 回归通过; 连续切源与长时播放需要目标 iPhone 实测 |
| Jellyfin | 设置中添加、禁用及删除媒体库; 支持用户名/密码或 User ID/API Key; 查询与认证复用上游 | 新配置入口接通; 私人服务器认证与播放需实际账户验证 |
| BT | 原生 libtorrent、选集、按需验证分片、Range 供流、暂停/继续/删除、持久化磁力与恢复数据、缓存直接播放 | 本机真实 P2P、跨片读取、尾部 seek、取消、重复打开及离线恢复测试通过; iOS 构建与模拟器测试由 CI 记录 |
| 主客户端画中画 | mpv 软件 render API 写入 IOSurface-backed BGRA 缓冲池, 与当前音轨、字幕、暂停、倍速及 seek 共用会话; 有限 VOD 时间轴 | 有色彩信息的 SDR 输入可用; 输出最长边受缓冲尺寸限制; 模拟器帧测试不能替代真机 PiP、后台及音画同步验收 |
| AirPlay 视频 | FFmpeg 解码, Apple H.264/AAC 编码, 分片 MP4/HLS, 随机令牌 HTTP 供流, 系统视频路由; AVPlayer 仅作为远端传输器 | 原分辨率 SDR 与明确选择的 1080p 模式; 没有真实接收器证据时保持实验状态; 不能把屏幕镜像计为通过 |
| 性能 | 首帧/seek 耗时、有界内存/掉帧/温度/电量采样、JSON 导出 | 报告不包含 URL、请求头及账户; 没有实际采样时不填写推测结果 |
| 4K HDR / Dolby Vision 全保真 | 当前 SDR 输出路径限制已知 HDR/DV; PiP 也限制未知色彩输入 | 不属于本轮交付关卡; 不宣称 BGRA8 或 H.264 SDR 保留高位深/动态元数据 |

本表描述代码能力与证据边界。CI 成功、缓冲区测试、真机播放和接收端播放分别验收。

## 自动验证入口

- `cd app/ios-native/App && swift test`: 生产任务生命周期、进度合并、请求头、日志脱敏、弹幕、HTTP Range、媒体时间轴与性能记录策略。
- `.github/workflows/ios-native-tests.yml`: macOS 上执行纯 Swift 回归。
- `.github/workflows/ios-media-sdk.yml`: 固定 Xcode 26 和 MPVKit, 对生产 Swift/Objective-C 代码进行 SDK 检查; 执行 `MediaTests` 的实际解码帧、三缓冲上限、HTTP Range、HLS 转换及 HDR 拒绝测试。
- `.github/workflows/ios-libtorrent.yml`: iOS 原生引擎交叉编译与模拟器本机 P2P 回归。公网 DHT 冒烟为诊断项, 不作为确定性 P2P 测试的替代。
- `.github/workflows/ios-native.yml`: Kotlin facade 回归、原生引擎链接、AniCore 构建、App 归档和 FFmpeg 链接检查, 产出未签名 IPA。
- [FrameLab](FrameLab/README.md) 是独立 OpenGL 帧输出实验。主客户端采用软件 render API, 不把模拟器缺少 EAGL 接口的跳过结果计为生产帧输出通过。

## 使用检查

1. 设置 → 数据源 → 添加 Jellyfin。优先使用 HTTPS; 私人媒体库账户只保存在应用配置中, 错误提示不展示密码或 API Key。
2. 在选源中选择磁力/种子。播放后点“下载”固定缓存, 在缓存管理中暂停、继续、删除或直接播放。系统挂起应用时允许 BT 暂停。
3. 播放有明确 SDR 色彩信息的视频后使用画中画按钮。测试 MP4/MKV/WebM, H.264/HEVC/VP9/AV1, AAC/AC-3/E-AC-3/FLAC 与 SRT/ASS; 暂停、倍速、前后 seek、字幕/音轨切换、锁屏、返回页面及下一集分别记录。
4. 更多 → AirPlay 视频投送 → 选择画质 → 准备视频 → 选择同一 Wi-Fi 中支持视频的接收器。在线、BT 与 MKV 分别验证; 检查局域网权限、视频路由、全片 seek、暂停、断开路由及恢复本地播放。转换需要手机持续运行, 系统挂起时允许暂停。
5. 更多 → 导出性能报告。相同设备、样本、亮度与网络下比较冷启动、首帧、seek、重缓冲、内存、掉帧、温度和电量。

## 真机稳定性关卡

记录提交、IPA 构建、精确机型、系统版本、样本校验值与网络条件。

- 连续切集、换源、退出 50 次, 检查迟到回调、旧资源、双音、关闭后继续播放及内存增长。
- 播放、暂停、退出、断网重启、恢复网络, 检查本地进度、看过标记及 Bangumi 同步不串集; 已完成 BT 缓存应在无做种端时可读。
- 测试音频中断、拔耳机、旋转、锁屏和前后台切换, 检查 PiP 输出期间不调用后台 GPU 渲染。
- 1080p 连播 60 分钟、4K SDR 24/30fps 连播 30 分钟; 4K60 单独压力测试。同场景耗时或内存回退超过 10% 应说明或修复。
- 数量相同但内容不同的两集弹幕应更新; 检查来源过滤、彩色开关、暂停与全屏切换。
- 拒绝相册/局域网权限、截图失败、媒体初始化失败、删除正在播放的缓存及解析取消应有可恢复的状态。
