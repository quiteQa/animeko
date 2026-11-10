import AniCore
import AVFoundation
import SwiftUI

@main
struct AniNativeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 画中画与后台播放需要 playback 音频会话, 必须在任何播放开始前激活.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // 一起看的提示与跳转读取 AppServices, 必须位于 environment 之内
                .watchTogetherHost()
                .environment(services)
                .task { await services.observeSession() }
                .task { await services.observeSettings() }
                .task { await services.watchTogether.observe(core: services.core) }
        }
        .onChange(of: scenePhase) { _, phase in
            services.core.watchTogether.setAppForeground(foreground: phase == .active)
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
            Tab("探索", systemImage: "sparkles.tv") {
                NavigationStack {
                    ExploreScreen()
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

/// 条目详情的导航目标. 只需 id; 名称与封面用于详情加载前的占位.
struct SubjectRoute: Hashable {
    let id: Int32
    let name: String
    let imageUrl: String

    init(id: Int32, name: String, imageUrl: String) {
        self.id = id
        self.name = name
        self.imageUrl = imageUrl
    }

    init(_ subject: AniSubject) {
        self.init(id: subject.id, name: subject.displayName, imageUrl: subject.imageUrl)
    }
}

extension View {
    /// 让 `NavigationLink(value: SubjectRoute)` 跳转到条目详情.
    func subjectNavigation() -> some View {
        navigationDestination(for: SubjectRoute.self) { route in
            SubjectScreen(route: route)
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

    /// 一起看.
    let watchTogether = WatchTogetherModel()

    /// 设置. Kotlin 侧首次回调前为 `nil`.
    private(set) var settings: AniSettings?

    func observeSession() async {
        for await session in core.sessionUpdates {
            self.session = session
        }
    }

    func observeSettings() async {
        for await settings in core.settings.settingsUpdates {
            self.settings = settings
        }
    }
}
