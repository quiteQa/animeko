简体中文与 iOS 26 风格界面：玻璃效果悬浮导航、大标题、搜索入口、资料库、设置列表、页面转场和触感反馈。

这是面向 iPhone/iPad arm64 的 Release 优化构建。IPA 使用 ad-hoc 占位签名，安装时需要通过 SideStore、AltStore 或其他工具使用自己的 Apple 账号重新签名。此发行包不提供 App Store、TestFlight 或企业签名。

下载 `.ipa` 文件用于安装；`SHA256SUMS.txt` 提供文件校验值。最低系统版本 iOS 16。玻璃效果由跨平台 Compose/Haze 实现。

GitHub Actions 会检查 IPA 的完整性、设备平台、应用版本、嵌入框架及 arm64 主程序。此版本尚未经过 iOS 真机功能验证，因此标记为预发行版。
