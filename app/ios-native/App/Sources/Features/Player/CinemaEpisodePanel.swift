import AniCore
import SwiftUI

struct CinemaEpisodePanel: View {
    let model: PlayerModel
    let onClose: () -> Void
    let onSelect: (AniEpisode) -> Void

    private var episodes: [AniEpisode] {
        model.episodes.isEmpty ? [model.target.episode] : model.episodes
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("选集").font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !model.episodes.isEmpty {
                        Text("全 \(episodes.count) 话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭选集")
                .accessibilityIdentifier("cinema-episodes-close")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(episodes, id: \.id) { episode in
                            episodeRow(episode)
                                .id(episode.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .task(id: model.target.episode.id) {
                    proxy.scrollTo(model.target.episode.id, anchor: .center)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .overlay(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1).allowsHitTesting(false)
        }
        .accessibilityAction(.escape) { onClose() }
    }

    private func episodeRow(_ episode: AniEpisode) -> some View {
        let selected = episode.id == model.target.episode.id
        let shape = RoundedRectangle(cornerRadius: 10)
        return Button { onSelect(episode) } label: {
            HStack(spacing: 10) {
                CoverImage(url: episode.imageUrl.isEmpty ? model.target.subject.imageUrl : episode.imageUrl, cornerRadius: 6)
                    .frame(width: 76, height: 43)
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "waveform")
                                .font(.caption2.weight(.bold))
                                .padding(4)
                                .background(.black.opacity(0.78), in: .rect(cornerRadius: 4))
                                .padding(3)
                                .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if selected, model.duration > 0 {
                            let progress = min(1, max(0, model.currentTime / model.duration))
                            Capsule()
                                .fill(cinemaAccent)
                                .frame(width: 70 * progress, height: 2)
                                .padding(3)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("第 \(episode.sort) 话")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? cinemaAccent : Color.secondary)
                    if !episode.displayName.isEmpty {
                        Text(episode.displayName)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if episode.watched && !selected {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已看过")
                }
            }
            .padding(8)
            .frame(minHeight: 56)
            .background(selected ? cinemaAccent.opacity(0.15) : .clear, in: shape)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(cinemaAccent).frame(width: 2).padding(.vertical, 8)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
