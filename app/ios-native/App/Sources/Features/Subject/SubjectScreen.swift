import AniCore
import SwiftUI

@MainActor
@Observable
final class SubjectModel {
    private(set) var episodes: [AniEpisode] = []
    private(set) var summary = ""
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func load(subjectId: Int32, core: AniCore) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let detail = try await core.subjectDetail(subjectId: subjectId)
            episodes = detail.episodes
            summary = detail.subject.summary
        } catch {
            errorMessage = error.localizedDescription
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
    let subject: AniSubject

    @Environment(AppServices.self) private var services
    @State private var model = SubjectModel()
    @State private var playing: PlaybackTarget?

    var body: some View {
        List {
            Section {
                SubjectHeader(subject: subject, summary: model.summary.isEmpty ? subject.summary : model.summary)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("剧集") {
                if model.isLoading, model.episodes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("重试") { Task { await model.load(subjectId: subject.id, core: services.core) } }
                } else {
                    ForEach(model.episodes, id: \.id) { episode in
                        Button {
                            playing = PlaybackTarget(subject: subject, episode: episode)
                        } label: {
                            EpisodeRow(episode: episode)
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .navigationTitle(subject.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(subjectId: subject.id, core: services.core) }
        .refreshable { await model.load(subjectId: subject.id, core: services.core) }
        .fullScreenCover(item: $playing) { target in
            PlayerScreen(target: target)
        }
    }
}

private struct SubjectHeader: View {
    let subject: AniSubject
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                CoverImage(url: subject.imageUrl)
                    .frame(width: 110, height: 156)
                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.displayName)
                        .font(.title3.bold())
                        .textSelection(.enabled)
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
            if !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }
}

private struct EpisodeRow: View {
    let episode: AniEpisode

    var body: some View {
        HStack(spacing: 12) {
            Text(episode.sort)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tint)
                    .accessibilityLabel("已看过")
            }
        }
        .contentShape(.rect)
    }
}
