import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Cross-references declared NSUsageDescription / entitlement claims with
/// the binary's actual symbol references, surfacing two specific failure
/// modes:
///
///   * **declared but unused** — the developer asked for a permission the
///     binary contains no code path to use. Lazy declaration, copy-paste,
///     or a feature that's been removed but left in Info.plist.
///   * **used but undeclared** — the binary references a privacy-API
///     symbol but no matching usage description / entitlement. The first
///     time the API is called, the app will crash with a TCC violation —
///     unless the call is conditional on something we don't see.
struct PrivacyClaimsView: View {
    let inferred: [InferredCapability]

    var body: some View {
        let mismatched = inferred.filter { $0.declaredButNotJustified || $0.inferredButNotDeclared }
        if !mismatched.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Privacy claims vs. actual usage")
                InfoButton(articleID: "privacy-claims-mismatch")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where the bundle's declared privacy permissions don't line up with what the binary actually references.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(mismatched) { cap in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: cap.declaredButNotJustified
                                      ? "questionmark.circle.fill"
                                      : "exclamationmark.triangle.fill")
                                    .foregroundStyle(cap.declaredButNotJustified ? .yellow : .red)
                                Text(cap.category.rawValue.capitalized).font(.callout.bold())
                                Spacer()
                                Text(cap.declaredButNotJustified
                                     ? "declared, not used"
                                     : "used, not declared")
                                    .font(.caption)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background((cap.declaredButNotJustified ? Color.yellow : Color.red)
                                                .opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(cap.declaredButNotJustified ? .yellow : .red)
                            }
                            ForEach(cap.evidence, id: \.self) { ev in
                                Text("• \(ev)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
