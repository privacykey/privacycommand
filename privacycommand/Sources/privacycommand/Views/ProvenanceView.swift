import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

// MARK: - Provenance section

/// Where the app came from + integrity verification. Driven entirely by
/// `ProvenanceInfo` for the metadata, and a lazy SHA-256 button for the
/// content hash (so we don't read 100MB of executable on every analysis).
struct ProvenanceSection: View {
    let provenance: ProvenanceInfo
    let bundleURL: URL

    @State private var computedHash: String?
    @State private var isComputingHash = false
    @State private var hashError: String?
    @State private var pasteToCompare: String = ""
    @State private var compareResult: CompareResult?
    @State private var hashExpanded: Bool = false

    private enum CompareResult { case match, mismatch }

    var body: some View {
        GroupBox(label: HStack {
            Text("Provenance")
            InfoButton(articleID: "provenance")
        }) {
            VStack(alignment: .leading, spacing: 12) {
                whereFromSection
                quarantineSection
                Divider()
                hashSection
            }
            .padding(8)
        }
    }

    // MARK: - Where from

    @ViewBuilder
    private var whereFromSection: some View {
        if provenance.whereFromURLs.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("No download metadata.")
                    .foregroundStyle(.secondary).font(.callout)
                InfoButton(articleID: "kMDItemWhereFroms")
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                    Text("Downloaded from").font(.subheadline.bold())
                    InfoButton(articleID: "kMDItemWhereFroms")
                }
                ForEach(Array(provenance.whereFromURLs.enumerated()), id: \.offset) { idx, urlString in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(idx == 0 ? "Source URL" : "Referrer")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        if let url = URL(string: urlString), url.scheme != nil {
                            Link(urlString, destination: url)
                                .font(.callout.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        } else {
                            Text(urlString)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Quarantine

    @ViewBuilder
    private var quarantineSection: some View {
        if provenance.isQuarantined {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(.blue)
                Text("Quarantined").font(.subheadline.bold())
                if let agent = provenance.quarantineAgentName {
                    Text("by \(agent)").foregroundStyle(.secondary)
                }
                if let date = provenance.quarantineDate {
                    Text("on \(date.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                InfoButton(articleID: "com-apple-quarantine")
                Spacer()
                if let flags = provenance.quarantineFlagsHex {
                    Text("flags=\(flags)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "shield").foregroundStyle(.secondary)
                Text("No quarantine attribute.").foregroundStyle(.secondary).font(.callout)
                InfoButton(articleID: "com-apple-quarantine")
            }
        }
    }

    // MARK: - Hash

    @ViewBuilder
    private var hashSection: some View {
        DisclosureGroup(isExpanded: $hashExpanded) {
            hashExpansion
                .padding(.top, 6)
        } label: {
            hashLabel
        }
    }

    /// Compact one-line summary shown when collapsed. Conveys whether a
    /// hash has been computed and whether a comparison verified it, without
    /// needing the user to expand the section.
    private var hashLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "number").foregroundStyle(.secondary)
            Text("Main executable SHA-256").font(.subheadline.bold())
            Spacer()
            hashStatusChip
        }
    }

    @ViewBuilder
    private var hashStatusChip: some View {
        if isComputingHash {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("hashing…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let r = compareResult {
            HStack(spacing: 4) {
                Image(systemName: r == .match ? "checkmark.seal.fill" : "xmark.octagon.fill")
                Text(r == .match ? "verified" : "mismatch")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(r == .match ? .green : .red)
        } else if let hash = computedHash {
            Text("\(hash.prefix(8))…\(hash.suffix(4))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        } else if hashError != nil {
            Label("error", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        } else {
            Text("not computed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hashExpansion: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(provenance.mainExecutablePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                InfoButton(articleID: "sha256-verification")
            }

            HStack(spacing: 8) {
                if isComputingHash {
                    ProgressView().controlSize(.small)
                    Text("Hashing…").font(.callout).foregroundStyle(.secondary)
                } else if let hash = computedHash {
                    Text(hash)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hash, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy hash")
                } else if let err = hashError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).font(.callout)
                } else {
                    Button("Compute SHA-256") { computeHash() }
                        .buttonStyle(.borderedProminent)
                    Text("Reads \(URL(fileURLWithPath: provenance.mainExecutablePath).lastPathComponent) memory-mapped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Compare field — visible only after a hash exists.
            if computedHash != nil {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "equal.circle").foregroundStyle(.secondary)
                    TextField("Paste a SHA-256 from the developer's site…",
                              text: $pasteToCompare)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onChange(of: pasteToCompare) { _ in compareResult = nil }
                        .onSubmit { comparePaste() }
                    Button("Compare", action: comparePaste)
                        .disabled(pasteToCompare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let r = compareResult {
                    HStack(spacing: 6) {
                        Image(systemName: r == .match ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r == .match ? .green : .red)
                        Text(r == .match
                             ? "Match — the executable hash equals the pasted value."
                             : "Mismatch — the pasted hash does NOT match.")
                            .font(.callout)
                            .foregroundStyle(r == .match ? .green : .red)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func computeHash() {
        let url = URL(fileURLWithPath: provenance.mainExecutablePath)
        isComputingHash = true
        hashError = nil
        Task.detached {
            let outcome: Result<String, Error>
            do {
                let h = try ProvenanceReader.sha256(of: url)
                outcome = .success(h)
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                isComputingHash = false
                switch outcome {
                case .success(let h):  computedHash = h
                case .failure(let e):  hashError = "Failed: \(e.localizedDescription)"
                }
            }
        }
    }

    private func comparePaste() {
        let trimmed = pasteToCompare.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bail silently if there's nothing to compare against — clicking
        // away from / submitting an empty field shouldn't show a warning.
        guard !trimmed.isEmpty, let computed = computedHash else {
            compareResult = nil
            return
        }
        compareResult = ProvenanceReader.hashMatches(computed, trimmed) ? .match : .mismatch
    }
}

// MARK: - ATS section

struct ATSSection: View {
    let ats: ATSConfig

    var body: some View {
        GroupBox(label: HStack {
            Text("App Transport Security")
            InfoButton(articleID: "ats")
        }) {
            VStack(alignment: .leading, spacing: 6) {
                if ats.allowsArbitraryLoads {
                    flagRow("Arbitrary loads allowed", value: "yes",
                            articleID: "ats-arbitrary-loads", color: .red)
                }
                if ats.allowsArbitraryLoadsForMedia {
                    flagRow("Arbitrary loads — media", value: "yes",
                            articleID: "ats-arbitrary-media", color: .orange)
                }
                if ats.allowsArbitraryLoadsInWebContent {
                    flagRow("Arbitrary loads — WebView content", value: "yes",
                            articleID: "ats-arbitrary-web", color: .orange)
                }
                if ats.allowsLocalNetworking {
                    flagRow("Local networking allowed", value: "yes",
                            articleID: "ats-local-networking", color: .blue)
                }
                if ats.exceptionDomains.isEmpty == false {
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 6) {
                        Text("Exception domains (\(ats.exceptionDomains.count))")
                            .font(.subheadline.bold())
                        InfoButton(articleID: "ats-exception-domains")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(ats.exceptionDomains) { ex in
                            atsRow(ex)
                        }
                    }
                } else if !ats.allowsArbitraryLoads
                            && !ats.allowsArbitraryLoadsForMedia
                            && !ats.allowsArbitraryLoadsInWebContent
                            && !ats.allowsLocalNetworking {
                    Text("Default policy — TLS required for all connections.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(8)
        }
    }

    private func flagRow(_ label: String, value: String,
                         articleID: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
            InfoButton(articleID: articleID)
        }
    }

    private func atsRow(_ ex: ATSException) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            Text(ex.domain)
                .font(.callout.monospaced())
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                if ex.allowsInsecureHTTPLoads { tag("HTTP allowed", color: .red) }
                if ex.allowsArbitraryLoads    { tag("arbitrary", color: .red) }
                if ex.includesSubdomains      { tag("incl. subdomains", color: .orange) }
                if let tls = ex.minimumTLSVersion { tag("min \(tls)", color: .secondary) }
                if !ex.requiresForwardSecrecy { tag("no forward secrecy", color: .orange) }
            }
            Spacer()
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
}
