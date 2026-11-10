import AniCore
import SwiftUI

@MainActor
@Observable
final class CollectionModel {
    var type: AniCollectionType = .doing
    private(set) var items: [AniCollectionItem] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    private static let limit: Int32 = 100

    /// 观察本地缓存. 切换类型时由视图的 `.task(id:)` 重新调用.
    func observe(core: AniCore) async {
        items = []
        for await update in core.collectionUpdates(type: type, limit: Self.limit) {
            if let list = update.items {
                items = list
            } else {
                errorMessage = update.error
            }
        }
    }

    /// 从服务器拉取最新收藏到本地缓存, 结果经 `observe` 送达.
    func refresh(core: AniCore) async {
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            try await core.refreshCollections(type: type, limit: Self.limit)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CollectionScreen: View {
    @Environment(AppServices.self) private var services
    @State private var model = CollectionModel()
    @State private var login = BangumiLoginModel()
    @State private var playing: PlaybackTarget?
    @State private var openingEpisode: Int32?

    var body: some View {
        Group {
            if let session = services.session, !session.loggedIn || !session.bangumiConnected {
                ContentUnavailableView {
                    Label("登录以同步追番", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("使用 Bangumi 账号登录后, 这里会显示你的收藏与观看进度。")
                } actions: {
                    Button(session.loggedIn ? "绑定 Bangumi" : "使用 Bangumi 登录") {
                        login.start(core: services.core)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(login.isRunning)
                }
            } else {
                list
            }
        }
        .navigationTitle("追番")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("收藏类型", selection: $model.type) {
                    ForEach(AniCollectionType.selectable, id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .bangumiLogin(login)
        .navigationDestination(item: $playing) { target in
            EpisodePlayerPage(target: target)
        }
    }

    private var list: some View {
        List(model.items, id: \.subject.id) { item in
            NavigationLink(value: SubjectRoute(item.subject)) {
                CollectionRow(item: item, isOpening: openingEpisode == item.nextEpisodeId?.int32Value) {
                    play(item)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.items.isEmpty, !model.isRefreshing {
                if let message = model.errorMessage {
                    ContentUnavailableView("加载失败", systemImage: "wifi.exclamationmark", description: Text(message))
                } else {
                    ContentUnavailableView("没有\(model.type.title)的番剧", systemImage: model.type.systemImage)
                }
            }
        }
        .refreshable { await model.refresh(core: services.core) }
        .task(id: model.type) {
            async let observing: Void = model.observe(core: services.core)
            await model.refresh(core: services.core)
            await observing
        }
    }

    /// 直接播放下一集: 先读取条目详情拿到剧集信息.
    private func play(_ item: AniCollectionItem) {
        guard let episodeId = item.nextEpisodeId?.int32Value, openingEpisode == nil else { return }
        openingEpisode = episodeId
        Task {
            defer { openingEpisode = nil }
            guard let detail = try? await services.core.subjectDetail(subjectId: item.subject.id),
                  let episode = detail.episodes.first(where: { $0.id == episodeId }) else { return }
            playing = PlaybackTarget(subject: detail.subject, episode: episode)
        }
    }
}

private struct CollectionRow: View {
    let item: AniCollectionItem
    let isOpening: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: item.subject.imageUrl)
                .frame(width: 60, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subject.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Text(item.progressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.nextEpisodeId != nil {
                Button(action: onPlay) {
                    if isOpening {
                        ProgressView()
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("播放下一集")
            }
        }
        .padding(.vertical, 4)
    }
}
