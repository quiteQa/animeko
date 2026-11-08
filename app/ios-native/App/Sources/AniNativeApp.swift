import AniCore
import AVFoundation
import SwiftUI

@main
struct AniNativeApp: App {
    @State private var services = AppServices()

    init() {
        // 画中画与后台播放需要 playback 音频会话, 必须在任何播放开始前激活.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SearchScreen()
            }
            .environment(services)
        }
    }
}

/// 进程级依赖. `AniCore` 在首次访问时启动 Kotlin 侧 (Koin, 数据库, 数据源订阅).
@MainActor
@Observable
final class AppServices {
    @ObservationIgnored
    lazy var core: AniCore = AniCoreStarterKt.startAniCore()
}
