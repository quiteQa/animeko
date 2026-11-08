import AniCore
import SwiftUI

/// 缓存管理. `subjectId` 为 0 时显示所有条目的缓存, 按条目分组.
/// 缓存完成的剧集在播放时自动优先使用, 不需要在这里单独播放.
struct DownloadsScreen: View {
    var subjectId: Int32 = 0

    @Environment(AppServices.self) private var services
    @State private var downloads: [AniDownload] = []
    @State private var loaded = false
    @State private var pendingDelete: AniDownload?

    private struct SubjectGroup: Identifiable {
        let id: Int32
        let name: String
        let items: [AniDownload]
    }

    /// 按条目分组, 剧集按序号的自然顺序 (2 在 10 之前) 排列.
    private var groups: [SubjectGroup] {
        Dictionary(grouping: downloads, by: \.subjectId)
            .map { id, items in
                SubjectGroup(
                    id: id,
                    name: items.first?.subjectName ?? "",
                    items: items.sorted { $0.episodeSort.localizedStandardCompare($1.episodeSort) == .orderedAscending },
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(subjectId == 0 ? group.name : "") {
                    ForEach(group.items, id: \.id) { download in
                        DownloadRow(download: download)
                            .swipeActions {
                                Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = download }
                                pauseResumeButton(download)
                            }
                            .contextMenu {
                                pauseResumeButton(download)
                                Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = download }
                            }
                    }
                }
            }
        }
        .overlay {
            if loaded, downloads.isEmpty {
                ContentUnavailableView(
                    "没有缓存",
                    systemImage: "arrow.down.circle",
                    description: Text("在播放页点击缓存按钮, 可以把正在播放的资源缓存到本机。"),
                )
            } else if !loaded {
                ProgressView()
            }
        }
        .navigationTitle(subjectId == 0 ? "缓存管理" : "本番缓存")
        .confirmationDialog(
            "删除缓存?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete,
        ) { download in
            Button("删除第 \(download.episodeSort) 话的缓存", role: .destructive) {
                services.core.downloads.delete(ids: [download.id])
            }
        }
        .task {
            for await list in services.core.downloads.downloadUpdates(subjectId: subjectId) {
                downloads = list
                loaded = true
            }
        }
    }

    @ViewBuilder
    private func pauseResumeButton(_ download: AniDownload) -> some View {
        switch download.state {
        case "IN_PROGRESS":
            Button("暂停", systemImage: "pause") { services.core.downloads.pause(ids: [download.id]) }
                .tint(.orange)
        case "PAUSED", "FAILED":
            Button("继续", systemImage: "play") { services.core.downloads.resume(ids: [download.id]) }
                .tint(.green)
        default:
            EmptyView()
        }
    }
}

private struct DownloadRow: View {
    let download: AniDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(download.episodeName.isEmpty ? "第 \(download.episodeSort) 话" : "\(download.episodeSort) · \(download.episodeName)")
                    .lineLimit(1)
                Spacer()
                if download.busy {
                    ProgressView().controlSize(.small)
                }
            }
            if download.state == "IN_PROGRESS" || download.state == "PAUSED" {
                ProgressView(value: Double(max(download.progress, 0)))
            }
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(download.state == "FAILED" ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusLine: String {
        let size = download.totalBytes > 0
            ? ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file)
            : nil
        let state: String = switch download.state {
        case "IN_PROGRESS":
            download.speedBytesPerSecond > 0
                ? "下载中 · \(ByteCountFormatter.string(fromByteCount: download.speedBytesPerSecond, countStyle: .file))/s"
                : "下载中"
        case "PAUSED": "已暂停"
        case "FAILED": "失败"
        case "COMPLETED": "已完成"
        default: download.state
        }
        let percent = download.progress >= 0 && download.state != "COMPLETED"
            ? "\(Int(download.progress * 100))%"
            : nil
        return [state, percent, size, download.mediaSourceId].compactMap { $0 }.joined(separator: " · ")
    }
}
