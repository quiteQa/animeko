# libtorrent for iOS (M0)

把 libtorrent 与上游 anitorrent 的 C++ 封装 (`session_t` 等) 交叉编译到 iOS, 产出 `LibTorrent.xcframework`
(真机与模拟器 arm64 的合并静态库, 含 OpenSSL). 版本与上游 anitorrent 的原生构建一致, 见 `versions.env`.

```shell
./build-ios.sh build      # 需要 macOS, Xcode, CMake
./run-smoke.sh build      # 在模拟器中运行冒烟测试
```

冒烟测试 (`smoke/main.cpp`) 启动会话并监听端口, 连上 DHT, 尝试通过 DHT 获取一个公开种子的元数据,
再启动一个 anitorrent `session_t`. CI: `.github/workflows/ios-libtorrent.yml`.

iOS 会挂起后台应用, BT 只能在前台下载与做种.
