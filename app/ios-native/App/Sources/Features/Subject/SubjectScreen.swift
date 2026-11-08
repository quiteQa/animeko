import AniCore
import SwiftUI

@MainActor
@Observable
final class SubjectModel {
    private(set) var detail: AniSubjectDetail?
    private(set) var errorMessage: String?
    private(set) var actionError: String?

    /// 观察条目详情; 收藏或观看状态变更后自动更新.
    func observe(subjectId: Int32, core: AniCore) async {
        errorMessage = nil
        for await update in core.subjectDetailUpdates(subjectId: subjectId) {
            switch update {
            case .value(let detail):
                self.detail = detail
                errorMessage = nil
            case .failure(let message):
                errorMessage = message
            }
        }
    }

    func setCollectionType(_ type: AniCollectionType, subjectId: Int32, core: AniCore) async {
        await perform { try await core.setSubjectCollectionType(subjectId: subjectId, type: type) }
    }

    func setWatched(_ watched: Bool, episode: AniEpisode, subjectId: Int32, core: AniCore) async {
        await perform { try await core.setEpisodeWatched(subjectId: subjectId, episodeId: episode.id, watched: watched) }
    }

    private func perform(_ action: () async throws -> Void) async {
        actionError = nil
        do {
            try await action()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// 播放页的入口参数.
struct PlaybackTarget: Identifiable, Hashable {
    let subject: AniSubject
    let episode: AniEpisode
    var id: Int32 { episode.id }
}

struct SubjectScreen: View {
    let route: SubjectRoute

    @Environment(AppServices.self) private var services
    @State private var model = SubjectModel()
    @State private var playing: PlaybackTarget?
    @State private var reloadToken = 0

    private var subjectId: Int32 { route.id }

    private var nextEpisode: AniEpisode? {
        guard let detail = model.detail, let id = detail.nextEpisodeId?.int32Value else { return nil }
        return detail.episodes.first { $0.id == id }
    }

    var body: some View {
        List {
            Section {
                SubjectHeader(subject: model.detail?.subject, route: route)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let next = nextEpisode, let subject = model.detail?.subject {
                Section {
                    Button {
                        playing = PlaybackTarget(subject: subject, episode: next)
                    } label: {
                        Label("继续观看 第 \(next.sort) 话", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if let message = model.actionError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section {
                NavigationLink {
                    CommentsScreen(source: .subjectReviews(subjectId), title: "评价")
                } label: {
                    Label("评价", systemImage: "text.bubble")
                }
                NavigationLink {
                    DownloadsScreen(subjectId: subjectId)
                } label: {
                    Label("本番缓存", systemImage: "arrow.down.circle")
                }
            }
            Section("剧集") {
                episodes
            }
        }
        .navigationTitle(model.detail?.subject.displayName ?? route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if services.isLoggedIn {
                ToolbarItem(placement: .primaryAction) { collectionMenu }
            }
        }
        .task(id: reloadToken) { await model.observe(subjectId: subjectId, core: services.core) }
        .refreshable { reloadToken += 1 }
        .fullScreenCover(item: $playing) { target in
            PlayerScreen(target: target)
        }
    }

    @ViewBuilder
    private var episodes: some View {
        if let detail = model.detail {
            ForEach(detail.episodes, id: \.id) { episode in
                Button {
                    playing = PlaybackTarget(subject: detail.subject, episode: episode)
                } label: {
                    EpisodeRow(episode: episode, isNext: episode.id == nextEpisode?.id)
                }
                .tint(.primary)
                .swipeActions(edge: .trailing) {
                    if services.isLoggedIn { watchedButton(for: episode) }
                }
                .contextMenu {
                    if services.isLoggedIn { watchedButton(for: episode) }
                }
            }
        } else if let message = model.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            Button("重试") { reloadToken += 1 }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func watchedButton(for episode: AniEpisode) -> some View {
        Button {
            Task { await model.setWatched(!episode.watched, episode: episode, subjectId: subjectId, core: services.core) }
        } label: {
            if episode.watched {
                Label("取消看过", systemImage: "arrow.uturn.backward.circle")
            } else {
                Label("标记看过", systemImage: "checkmark.circle")
            }
        }
        .tint(episode.watched ? .gray : .green)
    }

    private var collectionMenu: some View {
        let current = model.detail?.collectionType ?? .notCollected
        return Menu {
            Picker("收藏", selection: Binding(
                get: { current },
                set: { type in
                    Task { await model.setCollectionType(type, subjectId: subjectId, core: services.core) }
                },
            )) {
                ForEach(AniCollectionType.selectable, id: \.self) { type in
                    Label(type.title, systemImage: type.systemImage).tag(type)
                }
            }
            if current != .notCollected {
                Divider()
                Button("取消收藏", systemImage: "trash", role: .destructive) {
                    Task { await model.setCollectionType(.notCollected, subjectId: subjectId, core: services.core) }
                }
            }
        } label: {
            Label(current.title, systemImage: current == .notCollected ? "plus" : current.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel("收藏状态: \(current.title)")
    }
}

/// 详情加载前用 [route] 中的名称与封面占位.
private struct SubjectHeader: View {
    let subject: AniSubject?
    let route: SubjectRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                CoverImage(url: subject?.imageUrl ?? route.imageUrl)
                    .frame(width: 110, height: 156)
                VStack(alignment: .leading, spacing: 6) {
                    Text(subject?.displayName ?? route.name)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    if let subject {
                        if subject.name != subject.displayName {
                            Text(subject.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(subject.subtitleLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let summary = subject?.summary, !summary.isEmpty {
                ExpandableText(text: summary)
            }
        }
        .padding()
    }
}

private struct ExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 5)
                .textSelection(.enabled)
            Button(expanded ? "收起" : "展开") {
                withAnimation { expanded.toggle() }
            }
            .font(.callout)
        }
    }
}

private struct EpisodeRow: View {
    let episode: AniEpisode
    let isNext: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(episode.sort)
                .font(.body.monospacedDigit())
                .foregroundStyle(isNext ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(minWidth: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.displayName.isEmpty ? "第 \(episode.sort) 话" : episode.displayName)
                    .lineLimit(1)
                if !episode.airDate.isEmpty {
                    Text(episode.airDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if episode.watched {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("已看过")
            }
        }
        .contentShape(.rect)
    }
}
