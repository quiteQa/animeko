import AniCore
import SwiftUI

/// 手动查找: 直接浏览某个数据源的条目, 线路与剧集, 由用户指定哪一项对应正在观看的剧集.
/// 浏览结果原样列出, 不做匹配, 不排序, 不过滤.
struct ManualBrowsePage: View {
    let player: PlayerModel
    /// 点选剧集并成功提交后调用 (关闭面板)
    let onPlayed: () -> Void

    @Environment(AppServices.self) private var services

    private var model: ManualBrowseModel { player.manualBrowse }

    var body: some View {
        Group {
            if model.openedSubject != nil {
                SubjectEpisodesView(player: player, onPlayed: onPlayed)
            } else {
                searchView
            }
        }
        .task {
            if let session = player.currentSession { await model.loadIfNeeded(session: session) }
        }
    }

    private var searchView: some View {
        @Bindable var model = model
        return List {
            Section {
                sourceMenu
                HStack {
                    TextField("关键字", text: $model.keyword)
                        .submitLabel(.search)
                        .onSubmit { run { await model.search(session: $0) } }
                    Button("搜索") { run { await model.search(session: $0) } }
                        .disabled(model.keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("找到对应的条目后, 选择线路与剧集, 把它作为第 \(player.target.episode.sort) 话播放。")
            }

            switch model.results {
            case .idle:
                EmptyView()
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("重试") { run { await model.search(session: $0) } }
                }
            case .loaded(let subjects):
                Section("\(subjects.count) 个结果") {
                    ForEach(subjects, id: \.url) { subject in
                        Button {
                            run { await model.openSubject(subject, session: $0) }
                        } label: {
                            HStack {
                                Text(subject.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.sourcesLoaded, model.sources.isEmpty {
                ContentUnavailableView(
                    "没有可浏览的数据源",
                    systemImage: "magnifyingglass",
                    description: Text("已启用的数据源都不支持手动查找。"),
                )
            }
        }
    }

    /// 源用下拉菜单选择: 数量没有上限, 横排放不下.
    private var sourceMenu: some View {
        Menu {
            ForEach(model.sources, id: \.instanceId) { source in
                Button {
                    run { await model.selectSource(source.instanceId, session: $0) }
                } label: {
                    if source.instanceId == model.selectedSourceId {
                        Label(source.displayName, systemImage: "checkmark")
                    } else {
                        Text(source.displayName)
                    }
                }
            }
        } label: {
            LabeledContent("数据源", value: model.selectedSource?.displayName ?? "选择数据源")
        }
        .disabled(model.sources.isEmpty)
    }

    private func run(_ action: @escaping (AniEpisodeSession) async -> Void) {
        guard let session = player.currentSession else { return }
        Task { await action(session) }
    }
}

/// 打开的条目: 线路选择与剧集网格.
private struct SubjectEpisodesView: View {
    let player: PlayerModel
    let onPlayed: () -> Void

    @Environment(AppServices.self) private var services

    private var model: ManualBrowseModel { player.manualBrowse }

    private var remember: Bool { services.settings?.rememberManualSelection ?? true }

    var body: some View {
        @Bindable var model = model
        return List {
            Section {
                Button {
                    model.closeSubject()
                } label: {
                    Label("返回搜索结果", systemImage: "chevron.left")
                }
                Text(model.openedSubject?.name ?? "")
                    .font(.headline)
            }

            switch model.channels {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("重试") {
                        guard let session = player.currentSession, let subject = model.openedSubject else { return }
                        Task { await model.openSubject(subject, session: session) }
                    }
                }
            case .loaded(let channels):
                if channels.isEmpty {
                    Text("这个条目没有剧集").foregroundStyle(.secondary)
                } else {
                    content(channels: channels, selectedChannel: $model.selectedChannelIndex)
                }
            }

            if let error = model.playError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func content(channels: [AniBrowseChannel], selectedChannel: Binding<Int>) -> some View {
        if channels.count > 1 {
            Section {
                Picker("线路", selection: selectedChannel) {
                    ForEach(channels, id: \.index) { channel in
                        Text(channel.label.isEmpty ? "线路 \(channel.index + 1)" : channel.label)
                            .tag(Int(channel.index))
                    }
                }
            }
        }
        if let channel = channels.first(where: { Int($0.index) == selectedChannel.wrappedValue }) ?? channels.first {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(channel.episodes, id: \.index) { episode in
                        EpisodeCell(
                            episode: episode,
                            isPreselected: episode.index == channel.preselectedEpisodeIndex,
                            isBusy: model.isPlaying,
                        ) {
                            play(Int(episode.index))
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("作为第 \(player.target.episode.sort) 话播放")
                    Spacer()
                    Toggle("记住选择", isOn: Binding(
                        get: { remember },
                        set: { player.setRememberManualSelection($0) },
                    ))
                    .fixedSize()
                    .font(.caption)
                }
            } footer: {
                Text(remember
                    ? "之后每一集会自动选择这条线路里对应位置的一项。在其他页面换源会结束记忆。"
                    : "只对本集有效, 下一集照常自动匹配。")
            }
        }
    }

    private func play(_ episodeIndex: Int) {
        guard let session = player.currentSession else { return }
        Task {
            if await model.play(episodeIndex: episodeIndex, remember: remember, session: session) {
                onPlayed()
            }
        }
    }
}

private struct EpisodeCell: View {
    let episode: AniBrowseEpisode
    let isPreselected: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isPreselected {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.glass)
            }
        }
        .disabled(isBusy)
    }

    private var button: some View {
        Button(action: action) {
            Text(episode.name)
                .font(.subheadline)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .accessibilityHint(isPreselected ? "推荐: 对应正在观看的一集" : "")
    }
}
