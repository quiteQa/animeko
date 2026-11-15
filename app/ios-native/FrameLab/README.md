# mpv 帧输出实验

独立的 iOS 验证 App, 使用与主客户端相同的 MPVKit `1.1.0-n9.0.2`。不依赖 AniCore / Compose, 不修改主客户端播放器。

## 验证内容

```
mpv 解码与时钟
    ↓ OpenGL render API (独立渲染队列)
IOSurface-backed BGRA CVPixelBuffer (池上限 3)
    ↓ CMSampleBuffer, host-clock 显示时间戳
AVSampleBufferDisplayLayer
    ↓
AVPictureInPictureController
```

- client API 与 render API 在独立队列执行, 不在渲染线程调用需要 `mpv_handle` 的 API, 不建立跨队列同步等待。
- GPU 绘制完成后才交出像素缓冲区; 没有逐帧截图、CPU 像素回读或 AVPlayer 解码。测试会读缓冲区检查上下方向。
- 输入只接受本地文件。BT、网络供流与 VOD 媒体时间轴映射不在此实验内。
- 明确的 SDR 白名单; HDR10、HLG、Dolby Vision 和未知色彩信息不进入 BGRA8 输出。主客户端的高位深/DV 要求保持阻塞。
- 当前 MPVKit 在 iOS 上禁用 VideoToolbox/OpenGL 互操作, 因此实验使用 `videotoolbox-copy`。它不能作为零复制、4K HDR 或低功耗达标的证据。
- 画中画由系统 sample-buffer 接口承接; 需要真机验证启动、暂停、后台、返回界面及音画同步。模拟器帧测试不等于画中画测试通过。

## 构建与测试

需要 macOS、Xcode 26 和 XcodeGen:

```sh
cd app/ios-native/FrameLab
xcodegen generate
xcodebuild test -project NativeFrameLab.xcodeproj -scheme NativeFrameLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

`.github/workflows/ios-frame-lab.yml` 自动选择可用 iPhone 模拟器, 验证真实 mpv 解码输出的像素方向、时间戳、三缓冲区背压和 HDR 拦截。测试通过后归档未签名 FrameLab IPA, 供个人设备侧载验证。

启动 App 后打开本地 SDR 样本, 检查接收帧数持续增加, 再手动启动系统画中画。HDR 样本必须显示拦截原因且不输出视频帧。

## 测试资源

`Tests/Fixtures` 是 FFmpeg 生成的纯色测试视频, 不含第三方媒体内容。它们是自动测试资源, 不是验证截图或录屏。

- `sdr-pattern.mp4`: H.264 / BT.709, 上红下蓝, 160×90, 24fps, 3 秒。
- `hdr10-pattern.mp4`: HEVC Main 10 / BT.2020 / SMPTE ST 2084, 160×90, 24fps, 1 秒; 用于测试拦截, 不能验证 HDR 保真。

生成方式:

```sh
ffmpeg -f lavfi -i 'color=c=red:s=160x90:r=24:d=3,drawbox=x=0:y=45:w=160:h=45:color=blue:t=fill' \
  -c:v libx264 -threads 1 -crf 18 -x264-params 'colorprim=bt709:transfer=bt709:colormatrix=bt709' \
  -pix_fmt yuv420p -color_primaries 1 -color_trc 1 -colorspace 1 -movflags +faststart sdr-pattern.mp4
ffmpeg -f lavfi -i 'color=c=white:s=160x90:r=24:d=1' -c:v libx265 -threads 1 \
  -x265-params 'pools=1:frame-threads=1:log-level=error:colorprim=9:transfer=16:colormatrix=9:hdr10=1:repeat-headers=1' \
  -pix_fmt yuv420p10le -color_primaries 9 -color_trc 16 -colorspace 9 -tag:v hvc1 -movflags +faststart hdr10-pattern.mp4
```

## 后续关卡

本实验验证 SDR 的系统输出链路。首版仍需要原生高位深帧输出补丁、准确的媒体时间轴映射、字幕验证、HDR/DV 元数据与增强层核对, 以及真机/接收端实测。实验成功不自动解除这些阻塞。
