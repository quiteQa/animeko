import SwiftUI

struct AirPlaySheet: View {
    @Bindable var model: PlayerModel
    @State private var compatible1080 = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("投送画质", selection: $compatible1080) {
                        Text("原分辨率 SDR").tag(false)
                        Text("1080p 兼容模式").tag(true)
                    }
                    .disabled(model.airPlay.state == .preparing || model.airPlay.isConnected)
                    Text("手机将视频转换为 H.264 / AAC，通过局域网发送视频流。BT、MKV 和在线源使用同一路径。转换会消耗电量；请保持 Wi-Fi 连接。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("准备视频投送") {
                        guard let url = model.playbackURL else { return }
                        Task { await model.airPlay.prepare(url: url, headers: model.playable?.headers ?? [:], start: model.currentTime, compatible1080: compatible1080) }
                    }.disabled(model.playbackURL == nil || model.airPlay.state == .preparing || model.airPlay.isConnected)
                }
                Section("连接接收器") {
                    switch model.airPlay.state {
                    case .idle: Text("先准备视频，再选择 AirPlay 接收器")
                    case .preparing: HStack { ProgressView(); Text("正在生成本机视频分片…") }
                    case .ready: Text("视频已就绪，请选择支持视频 AirPlay 的电视或接收器")
                    case .connected: Label("正在直接投送视频", systemImage: "airplay.video")
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    }
                    if model.airPlay.state == .ready || model.airPlay.isConnected {
                        AirPlayRouteButton().frame(height: 44).accessibilityLabel("选择 AirPlay 视频接收器")
                    }
                    if model.airPlay.state != .idle { Button("结束投送") { model.airPlay.stop() } }
                }
            }
            .navigationTitle("AirPlay 视频投送")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
