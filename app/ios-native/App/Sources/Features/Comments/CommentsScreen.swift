import AniCore
import SwiftUI

enum CommentSource: Hashable {
    case episode(Int32)
    case subjectReviews(Int32)

    var canPost: Bool {
        if case .episode = self { true } else { false }
    }
}

@MainActor
@Observable
final class CommentsModel {
    let source: CommentSource
    private(set) var items: [AniComment] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var errorMessage: String?
    var draft = ""
    private(set) var isPosting = false

    private var cursor: String?
    private static let pageSize: Int32 = 30

    init(source: CommentSource) {
        self.source = source
    }

    func reload(core: AniCore) async {
        cursor = nil
        reachedEnd = false
        items = []
        await loadMore(core: core)
    }

    func loadMore(core: AniCore) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page: AniCommentPage
            switch source {
            case .episode(let id):
                page = try await core.episodeComments(episodeId: id, cursor: cursor, limit: Self.pageSize)
            case .subjectReviews(let id):
                page = try await core.subjectReviews(subjectId: id, cursor: cursor, limit: Self.pageSize)
            }
            items.append(contentsOf: page.items.filter { new in !items.contains { $0.id == new.id } })
            cursor = page.nextCursor
            reachedEnd = page.nextCursor == nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func post(core: AniCore) async {
        guard case .episode(let id) = source else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            try await core.postEpisodeComment(episodeId: id, text: text)
            draft = ""
            await reload(core: core)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CommentsScreen: View {
    @Environment(AppServices.self) private var services
    @State private var model: CommentsModel
    let title: String

    init(source: CommentSource, title: String) {
        _model = State(initialValue: CommentsModel(source: source))
        self.title = title
    }

    var body: some View {
        List {
            ForEach(model.items, id: \.id) { comment in
                CommentRow(comment: comment)
                    .onAppear {
                        if comment.id == model.items.last?.id {
                            Task { await model.loadMore(core: services.core) }
                        }
                    }
            }
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.items.isEmpty, !model.isLoading, model.errorMessage == nil {
                ContentUnavailableView("还没有评论", systemImage: "text.bubble")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if model.source.canPost, services.isLoggedIn {
                CommentComposer(model: model)
            }
        }
        .task { await model.reload(core: services.core) }
        .refreshable { await model.reload(core: services.core) }
    }
}

/// 发表评论的输入框. 登录后显示在评论列表底部.
struct CommentComposer: View {
    @Bindable var model: CommentsModel
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 8) {
            TextField("发表评论", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            Button {
                Task { await model.post(core: services.core) }
            } label: {
                if model.isPosting {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up")
                }
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(model.isPosting || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("发送")
        }
        .padding()
    }
}

struct CommentRow: View {
    let comment: AniComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: comment.authorAvatarUrl)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 36, height: 36)
            .clipShape(.circle)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(comment.authorName.isEmpty ? "匿名" : comment.authorName)
                        .font(.subheadline.weight(.semibold))
                    if comment.rating > 0 {
                        Label("\(comment.rating)", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(Date(timeIntervalSince1970: TimeInterval(comment.createdAtMillis) / 1000), style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(comment.text)
                    .font(.body)
                    .textSelection(.enabled)
                if !comment.replies.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(comment.replies.prefix(3), id: \.id) { reply in
                            (Text(reply.authorName).bold() + Text(": ") + Text(reply.text))
                                .font(.callout)
                                .lineLimit(4)
                        }
                        if comment.replyCount > 3 {
                            Text("共 \(comment.replyCount) 条回复")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                }
            }
        }
        .padding(.vertical, 4)
    }
}
