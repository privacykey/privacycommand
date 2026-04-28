import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Compact info-circle button. Tapping opens a popover containing the
/// matching `KnowledgeArticle`. Falls back to a plain tooltip if the article
/// id isn't known.
struct InfoButton: View {
    let articleID: String?
    var fallbackHelp: String? = nil

    @State private var showing = false

    var body: some View {
        if let id = articleID, let article = KnowledgeBase.article(id: id) {
            Button { showing.toggle() } label: {
                Image(systemName: "info.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(article.summary)   // hover tooltip is the one-liner
            .popover(isPresented: $showing, arrowEdge: .leading) {
                ArticlePopoverView(article: article)
                    .frame(width: 380)
                    .padding(16)
            }
        } else if let fallback = fallbackHelp {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .help(fallback)
        }
        // No article + no fallback → render nothing.
    }
}

private struct ArticlePopoverView: View {
    let article: KnowledgeArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(article.title).font(.headline)
            }
            Text(article.summary)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = article.detail {
                Divider()
                ScrollView {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            if let url = article.learnMoreURL {
                Divider()
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Learn more on developer.apple.com")
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .font(.caption)
                }
            }
        }
    }
}
