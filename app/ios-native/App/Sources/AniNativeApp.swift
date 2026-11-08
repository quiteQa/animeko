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
            RootView()
                .environment(services)
                .task { await services.observeSession() }
        }
    }
}

private struct RootView: View {
    var body: some View {
        TabView {
            Tab("追番", systemImage: "play.square.stack") {
                NavigationStack {
                    CollectionScreen()
                        .subjectNavigation()
                }
            }
            Tab("我的", systemImage: "person.crop.circle") {
                NavigationStack {
                    AccountScreen()
                }
            }
            Tab(role: .search) {
                NavigationStack {
                    SearchScreen()
                        .subjectNavigation()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

extension View {
    /// 让 `NavigationLink(value: AniSubject)` 跳转到条目详情.
    func subjectNavigation() -> some View {
        navigationDestination(for: AniSubject.self) { subject in
            SubjectScreen(subject: subject)
        }
    }
}

/// 进程级依赖与全局状态. `AniCore` 在首次访问时启动 Kotlin 侧 (Koin, 数据库, 数据源订阅).
@MainActor
@Observable
final class AppServices {
    @ObservationIgnored
    lazy var core: AniCore = AniCoreStarterKt.startAniCore()

    /// 登录状态. Kotlin 侧首次回调前为 `nil`.
    private(set) var session: AniSession?

    var isLoggedIn: Bool { session?.loggedIn == true }

    func observeSession() async {
        for await session in core.sessionUpdates {
            self.session = session
        }
    }
}
