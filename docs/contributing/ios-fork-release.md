# Fork 的 iOS IPA 发布

`.github/workflows/ios-ipa-release.yml` 是独立维护的 iOS 发布流程。它在公开仓库的标准 GitHub 托管 `macos-15-intel` runner 上运行，仅编译 iOS Release IPA；不调用上游的自托管 runner、签名服务、AI 发布说明或云存储。标准公开仓库 Actions 用量适用 GitHub 的免费政策。

流程需要仓库启用 GitHub Actions，允许 checkout、setup-java、Gradle 及 artifact 官方 Actions，并允许发布 job 使用 `contents: write`。它不需要 Apple Distribution 证书。

`release/ios26` 分支的代码推送触发构建与发布。启用 Actions 后，可向该分支提交创建 `ios26-build-*` 标签来触发首次构建。也可以从该分支手动运行 `iOS IPA Release`。Actions 的手动运行入口需要该 workflow 已存在于默认分支。

依次执行 CocoaPods 初始化、Kotlin/Native Release 编译、Xcode 设备 archive、IPA 打包、完整性及 arm64 检查，然后上传 IPA 和 SHA-256 校验文件到 GitHub Releases。构建失败时不会创建发行版。

资源同步先使用 Compose 的 `compose.ios.resources.platform=iphoneos` 和 `compose.ios.resources.archs=arm64` 参数预检查。Kotlin/Native Release 框架随后在单独的 Gradle 调用中编译和链接，使用 10 GiB JVM 堆内存及单 worker；立即打包为 tar.gz artifact 保存，保留执行权限和符号链接，再检查 arm64。CocoaPods 框架同步、Xcode archive 与 IPA 打包使用 2 GiB 的 Gradle 调用，明确排除已完成的 Native 链接任务。设备平台、arm64 架构和 Release 配置保持一致；`OVERRIDE_KOTLIN_BUILD_IDE_SUPPORTED=YES` 使 Kotlin 的 CocoaPods 脚本跳过重复构建。Gradle 依赖缓存允许该发布分支写入。

流程的版本由 `RELEASE_VERSION`、`package.version`、`ios.version.code` 和 `RELEASE_TAG` 指定。发布下一版时需要同时更新这四项。已有 Release 不会被覆盖。标签以 `ios26-` 开头，不触发上游的 `v*` 全平台发布流程。

`SOURCE_COMMIT` 明确指定应用源代码版本，checkout 后建立 `release/ios26` 本地分支，以保持应用 Git 信息与编译缓存一致。Release 标签指向该源代码提交；构建 workflow 的提交通过 Actions 运行记录追溯。发布下一版时同时更新 `SOURCE_COMMIT`。

构建开始时将这三个应用版本属性写入 runner 工作目录的 `gradle.properties`，使直接执行的 Gradle 任务和 CocoaPods/Xcode 启动的 Gradle 子构建使用一致版本。这个文件修改属于构建工作目录，不提交回仓库。

IPA 使用 ad-hoc 占位签名，用户通过 SideStore 或 AltStore 使用自己的 Apple 账号重签安装。App Store/TestFlight 分发需要专用 bundle ID、Apple Developer 成员资格、证书及 provisioning profile，使用项目的 `buildSignedReleaseIpa` 流程。
