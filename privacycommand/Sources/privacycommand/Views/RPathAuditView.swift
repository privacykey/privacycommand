import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct RPathAuditView: View {
    let audit: RPathAudit

    var body: some View {
        if !audit.entries.isEmpty || !audit.dylibs.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Dynamic linking surface")
                InfoButton(articleID: "rpath-hijacking")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    if !audit.entries.isEmpty {
                        Text("LC_RPATH entries").font(.subheadline.bold())
                        ForEach(audit.entries) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: icon(entry.kind))
                                    .foregroundStyle(colour(entry.kind))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.raw)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                    if let resolved = entry.resolvedPath {
                                        Text("→ \(resolved)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Text(entry.kind.rawValue.capitalized)
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(colour(entry.kind).opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(colour(entry.kind))
                            }
                        }
                        if audit.hijackableCount > 0 {
                            Text("\(audit.hijackableCount) user-writable rpath entr\(audit.hijackableCount == 1 ? "y" : "ies") could enable dylib hijacking.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }

                    if !audit.dylibs.isEmpty {
                        Divider()
                        DisclosureGroup("Linked dylibs (\(audit.dylibs.count))") {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(audit.dylibs, id: \.self) { d in
                                    Text(d).font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func icon(_ k: RPathAudit.Entry.Kind) -> String {
        switch k {
        case .relative:   return "arrow.turn.down.right"
        case .system:     return "lock"
        case .absolute:   return "folder"
        case .hijackable: return "exclamationmark.triangle.fill"
        }
    }
    private func colour(_ k: RPathAudit.Entry.Kind) -> Color {
        switch k {
        case .relative:   return .green
        case .system:     return .blue
        case .absolute:   return .secondary
        case .hijackable: return .red
        }
    }
}
