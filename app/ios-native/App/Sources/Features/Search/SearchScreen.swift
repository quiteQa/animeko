import AniCore
import SwiftUI

@MainActor
@Observable
final class SearchModel {
    var query = ""
    private(set) var results: [AniSubject] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var errorMessage: String?

    private var searchedKeyword = ""
    private var searchTask: Task<Void, Never>?

    private static let pageSize: Int32 = 20

    func submit(core: AniCore) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        searchTask?.cancel()
        searchedKeyword = keyword
        results = []
        reachedEnd = false
        loadPage(core: core)
    }

    func loadMoreIfNeeded(after subject: AniSubject, core: AniCore) {
        guard subject.id == results.last?.id, !isLoading, !reachedEnd else { return }
        loadPage(core: core)
    }

    private func loadPage(core: AniCore) {
        let keyword = searchedKeyword
        let offset = Int32(results.count)
        isLoading = true
        errorMessage = nil
        searchTask = Task {
            defer { if keyword == searchedKeyword { isLoading = false } }
            do {
                let page = try await core.searchSubjects(keyword: keyword, offset: offset, limit: Self.pageSize)
                guard !Task.isCancelled, keyword == searchedKeyword else { return }
                results.append(contentsOf: page.filter { new in !results.contains { $0.id == new.id } })
                reachedEnd = page.isEmpty
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SearchScreen: View {
    @Environment(AppServices.self) private var services
    @State private var model = SearchModel()

    var body: some View {
        List {
            ForEach(model.results, id: \.id) { subject in
                NavigationLink(value: subject) {
                    SubjectRow(subject: subject)
                }
                .onAppear { model.loadMoreIfNeeded(after: subject, core: services.core) }
            }
            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if let message = model.errorMessage, model.results.isEmpty {
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { model.submit(core: services.core) }
                }
            } else if model.results.isEmpty, !model.isLoading {
                ContentUnavailableView("搜索番剧", systemImage: "magnifyingglass", description: Text("输入番剧名称, 从 Bangumi 查找条目"))
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $model.query, prompt: "番剧名称")
        .onSubmit(of: .search) { model.submit(core: services.core) }
    }
}

private struct SubjectRow: View {
    let subject: AniSubject

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: subject.imageUrl)
                .frame(width: 64, height: 90)
            VStack(alignment: .leading, spacing: 4) {
                Text(subject.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if subject.name != subject.displayName {
                    Text(subject.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(subject.subtitleLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

extension AniSubject {
    var subtitleLine: String {
        [airDate, totalEpisodes > 0 ? "\(totalEpisodes) 话" : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct CoverImage: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}
