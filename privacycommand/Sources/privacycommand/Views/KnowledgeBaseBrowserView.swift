import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Browse-everything window for the KnowledgeBase. Sectioned sidebar
/// (sectioned by editorial category), live-search, detail pane on the right.
/// Designed for "I see a term I don't know in the report — let me look it up
/// without finding the right ⓘ button first".
struct KnowledgeBaseBrowserView: View {
    @State private var search: String = ""
    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280)
        } detail: {
            detail
        }
        .frame(minWidth: 880, minHeight: 560)
        .navigationTitle("Knowledge Base")
        .onAppear {
            // Land on the first article in the first non-empty group on
            // first open, so the detail pane isn't blank.
            if selectedID == nil {
                selectedID = KnowledgeBase.groupedArticles.first?.articles.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(filteredGroups, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.articles) { article in
                        Text(article.title)
                            .tag(article.id as String?)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search the Knowledge Base")
        .listStyle(.sidebar)
    }

    private var filteredGroups: [(category: String, articles: [KnowledgeArticle])] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let groups = KnowledgeBase.groupedArticles
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.articles.filter { article in
                article.title.lowercased().contains(q) ||
                article.summary.lowercased().contains(q) ||
                (article.detail?.lowercased().contains(q) ?? false) ||
                article.id.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : (group.category, hits)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let article = KnowledgeBase.article(id: id) {
            ArticleDetailView(article: article)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Pick an article from the sidebar")
                    .font(.headline)
                Text("\(KnowledgeBase.allArticles.count) articles total")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Article detail

private struct ArticleDetailView: View {
    let article: KnowledgeArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title).font(.largeTitle.bold())
                    Text(article.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                Text(article.summary)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = article.detail {
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if let url = article.learnMoreURL {
                    Divider()
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.square")
                            Text("Open authoritative reference")
                        }
                        .font(.callout.bold())
                    }
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
