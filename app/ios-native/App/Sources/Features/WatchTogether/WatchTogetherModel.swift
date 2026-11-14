import AniCore
import SwiftUI

/// 一起看的全局状态: 房间, 成员, 提示与 "房主在看其他条目" 的跳转.
///
/// 由 `AppServices` 持有; 播放器的上报与同步在 `PlayerModel` 中.
@MainActor
@Observable
final class WatchTogetherModel {
    /// Kotlin 侧首次回调前为 `nil`.
    private(set) var room: AniWatchTogetherRoom?
    /// 房主正在看其他条目时的跳转提示; 用户处理后清除.
    var pendingNavigation: AniWatchTogetherNavigation?
    /// 用户确认跳转后要打开的播放页.
    var openTarget: PlaybackTarget?
    /// 一次性的提示.
    var message: String?

    var isInRoom: Bool { room?.status == .inRoom }

    func observe(core: AniClient) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await room in core.watchTogether.roomUpdates { self.room = room }
            }
            group.addTask { @MainActor in
                for await event in core.watchTogether.eventUpdates {
                    if let navigation = event.navigation {
                        self.pendingNavigation = navigation
                    } else if let text = event.message {
                        self.message = text
                    }
                }
            }
        }
    }

    /// 打开房主正在看的剧集.
    func open(_ navigation: AniWatchTogetherNavigation, core: AniClient) async {
        pendingNavigation = nil
        do {
            let detail = try await core.subjectDetail(subjectId: navigation.subjectId)
            guard let episode = detail.episodes.first(where: { $0.id == navigation.episodeId }) else {
                message = "找不到房主正在看的剧集"
                return
            }
            openTarget = PlaybackTarget(subject: detail.subject, episode: episode)
        } catch {
            message = "打开房主正在看的剧集失败"
        }
    }
}

/// 根视图上的一起看提示与跳转.
struct WatchTogetherHost: ViewModifier {
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        @Bindable var watchTogether = services.watchTogether
        content
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if let navigation = watchTogether.pendingNavigation {
                        WatchTogetherNavigationBanner(navigation: navigation)
                    }
                    if let message = watchTogether.message {
                        Text(message)
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .glassEffect(.regular, in: .capsule)
                            .task(id: message) {
                                try? await Task.sleep(for: .seconds(2.5))
                                withAnimation { watchTogether.message = nil }
                            }
                    }
                }
                .padding(.top, 8)
                .animation(.smooth, value: watchTogether.pendingNavigation?.episodeId)
                .animation(.smooth, value: watchTogether.message)
            }
            .fullScreenCover(item: $watchTogether.openTarget) { target in
                NavigationStack {
                    EpisodePlayerPage(target: target)
                        .subjectNavigation()
                }
            }
    }
}

/// "房主正在看 ×× 第 N 话" 提示, 可前往或忽略.
struct WatchTogetherNavigationBanner: View {
    let navigation: AniWatchTogetherNavigation
    /// 前往之前执行, 如关闭当前全屏播放器.
    var beforeOpen: (@MainActor () async -> Void)?

    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("房主正在看").font(.caption).foregroundStyle(.secondary)
                Text("\(navigation.subjectName) 第 \(navigation.episodeSort) 话")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("忽略") { services.watchTogether.pendingNavigation = nil }
                .buttonStyle(.glass)
            Button("前往") {
                Task {
                    await beforeOpen?()
                    await services.watchTogether.open(navigation, core: services.core)
                }
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    func watchTogetherHost() -> some View { modifier(WatchTogetherHost()) }
}
