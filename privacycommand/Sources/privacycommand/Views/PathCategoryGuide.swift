import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Sheet listing every `PathCategory` with its KnowledgeBase article. Reached
/// from the FileAccessView's "What do these categories mean?" button so users
/// can answer "should I be worried that this app touched ~/Library/Mail?"
/// without us cluttering every table row with info-circle buttons.
struct PathCategoryGuide: View {
    let onClose: () -> Void

    /// Curated order: most-sensitive first, expected-and-mundane last. Mirrors
    /// the order someone scanning the file table would naturally want.
    private let orderedCategories: [PathCategory] = [
        .userLibraryKeychains,
        .userLibraryCookies,
        .userLibrarySSH,
        .userLibraryMail,
        .userLibraryMessages,
        .userLibraryCalendar,
        .userLibraryContacts,
        .userLibraryPhotos,
        .userLibrarySafari,
        .removableVolume,
        .networkVolume,
        .userLibraryContainers,
        .userLibraryAppSupport,
        .userLibraryCaches,
        .userLibraryPreferences,
        .userDocuments,
        .userDesktop,
        .userDownloads,
        .userMovies,
        .userMusic,
        .userPictures,
        .userHomeOther,
        .iCloudDrive,
        .applications,
        .temporary,
        .systemReadOnly,
        .bundleInternal,
        .unknown
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Path category guide").font(.title2.bold())
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.return)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("File events captured during a monitored run are labelled with a path category. Categories tell you, at a glance, what kind of data was touched. The risk classifier uses them to decide whether an event is **expected**, **sensitive**, or **surprising** for the app being audited.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    ForEach(orderedCategories, id: \.self) { cat in
                        if let article = KnowledgeBase.article(id: "path-\(cat.rawValue)") {
                            categoryCard(cat: cat, article: article)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    private func categoryCard(cat: PathCategory, article: KnowledgeArticle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cat.rawValue)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 4))
                Text(article.title).font(.headline)
            }
            Text(article.summary).font(.callout)
            if let detail = article.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    }
}
