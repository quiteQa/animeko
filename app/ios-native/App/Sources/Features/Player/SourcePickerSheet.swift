import AniCore
import SwiftUI

/// 选源面板 (P1 简版): 列出经过过滤与排序的候选资源, 点选即切换.
/// 完整的选源界面 (自动匹配 / 手动查找 / BT 三种模式) 在 P2 实现.
struct SourcePickerSheet: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let progress = model.progress, progress.completed < progress.total {
                    Section {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
                            Text("正在查询数据源 \(progress.completed)/\(progress.total)")
                        }
                    }
                }
                Section {
                    ForEach(model.candidates, id: \.mediaId) { candidate in
                        Button {
                            model.select(candidate)
                            dismiss()
                        } label: {
                            CandidateRow(candidate: candidate, isSelected: candidate.mediaId == model.selected?.mediaId)
                        }
                        .tint(.primary)
                        .disabled(!candidate.playable)
                    }
                } footer: {
                    if model.candidates.contains(where: { !$0.playable }) {
                        Text("灰色的资源在 iOS 上无法播放: iOS 没有本地 BT 引擎。")
                    }
                }
            }
            .overlay {
                if model.candidates.isEmpty {
                    ContentUnavailableView("暂无资源", systemImage: "square.stack", description: Text("数据源仍在查询中, 或没有找到这一集的资源"))
                }
            }
            .navigationTitle("选择资源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: AniMediaCandidate
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("正在播放")
            }
        }
        .contentShape(.rect)
    }

    private var details: String {
        [candidate.mediaSourceId, candidate.alliance, candidate.resolution, candidate.subtitleLanguages.joined(separator: "/")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
