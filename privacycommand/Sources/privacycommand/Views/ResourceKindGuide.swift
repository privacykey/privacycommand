import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Sheet listing every `OpenResource.Kind` with its KnowledgeBase article.
/// Reached from the ResourcesView "What do these mean?" button. Mirrors the
/// PathCategoryGuide pattern so users develop one mental model for "open
/// the explainer sheet".
struct ResourceKindGuide: View {
    let onClose: () -> Void

    /// Curated order: most-common-first, with edge cases at the end. Differs
    /// from `OpenResource.Kind.allCases` enum order so the user lands on the
    /// kinds they're most likely to ask about.
    private let orderedKinds: [OpenResource.Kind] = [
        .regularFile,
        .directory,
        .pipe,
        .fifo,
        .unixSocket,
        .ipv4Socket,
        .ipv6Socket,
        .characterDevice,
        .blockDevice,
        .psxshm,
        .psxsem,
        .kqueue,
        .event,
        .other
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Resource kinds").font(.title2.bold())
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.return)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Each row in the Resources tab is one file descriptor — anything the operating system identifies with a small integer the app can read or write to. Categories below come from `lsof`'s TYPE column.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    ForEach(orderedKinds, id: \.self) { kind in
                        if let article = KnowledgeBase.article(id: kind.kbArticleID) {
                            kindCard(kind: kind, article: article)
                        }
                    }

                    Divider().padding(.vertical, 6)

                    if let fdArticle = KnowledgeBase.article(id: "resource-fd") {
                        kindCard(kind: .other,   // unused for FD card; just reusing layout
                                 article: fdArticle,
                                 customIcon: "number")
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 580)
    }

    private func kindCard(kind: OpenResource.Kind,
                          article: KnowledgeArticle,
                          customIcon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: customIcon ?? kind.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(article.title).font(.headline)
            }
            Text(article.summary).font(.callout)
            if let detail = article.detail {
                Text(detail)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    }
}
