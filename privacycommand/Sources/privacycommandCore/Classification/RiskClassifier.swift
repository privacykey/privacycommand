import Foundation

/// Maps an event to one of `Risk.expected`, `Risk.sensitive`, `Risk.surprising`
/// based on a small explainable rule set.
public struct RiskClassifier: Sendable {

    public struct Rule: Codable, Hashable, Sendable {
        public let id: String
        public let category: PathCategory?      // optional path-category match
        public let op: FileEvent.Op?            // optional file op match
        public let declaredCategoryRequired: PrivacyCategory?  // category that must be in the static report's declared keys
        public let risk: Risk
        public let rationale: String

        public init(id: String, category: PathCategory?, op: FileEvent.Op?,
                    declaredCategoryRequired: PrivacyCategory?, risk: Risk, rationale: String) {
            self.id = id
            self.category = category
            self.op = op
            self.declaredCategoryRequired = declaredCategoryRequired
            self.risk = risk
            self.rationale = rationale
        }
    }

    public struct Decision: Sendable, Hashable {
        public let risk: Risk
        public let ruleID: String?
        public let rationale: String?
    }

    public let rules: [Rule]
    public let declaredCategories: Set<PrivacyCategory>

    public init(rules: [Rule] = RiskClassifier.builtinRules,
                declaredCategories: Set<PrivacyCategory> = []) {
        self.rules = rules
        self.declaredCategories = declaredCategories
    }

    public static func load(fromResource url: URL?,
                            declaredCategories: Set<PrivacyCategory>) -> RiskClassifier {
        if let url,
           let data = try? Data(contentsOf: url),
           let rules = try? JSONDecoder().decode([Rule].self, from: data) {
            return RiskClassifier(rules: rules, declaredCategories: declaredCategories)
        }
        return RiskClassifier(rules: builtinRules, declaredCategories: declaredCategories)
    }

    public func classify(file event: FileEvent) -> Decision {
        for rule in rules {
            if let cat = rule.category, cat != event.category { continue }
            if let op = rule.op, op != event.op { continue }
            if let needed = rule.declaredCategoryRequired,
               !declaredCategories.contains(needed) {
                // The rule fires only when the declared category is *missing*.
                return Decision(risk: rule.risk, ruleID: rule.id, rationale: rule.rationale)
            }
            if rule.declaredCategoryRequired == nil {
                return Decision(risk: rule.risk, ruleID: rule.id, rationale: rule.rationale)
            }
        }
        return Decision(risk: .expected, ruleID: nil, rationale: nil)
    }

    public static let builtinRules: [Rule] = [
        Rule(id: "R001-keychains",
             category: .userLibraryKeychains, op: nil,
             declaredCategoryRequired: nil,
             risk: .surprising,
             rationale: "Touches the keychain folder. Apps should use the Security framework, not the raw files."),
        Rule(id: "R002-cookies",
             category: .userLibraryCookies, op: nil,
             declaredCategoryRequired: nil,
             risk: .surprising,
             rationale: "Reads or writes browser cookie storage."),
        Rule(id: "R003-ssh",
             category: .userLibrarySSH, op: nil,
             declaredCategoryRequired: nil,
             risk: .surprising,
             rationale: "Touches ~/.ssh — high-value secrets."),
        Rule(id: "R004-mail",
             category: .userLibraryMail, op: nil,
             declaredCategoryRequired: nil,
             risk: .sensitive,
             rationale: "Reads Apple Mail's data store."),
        Rule(id: "R005-messages",
             category: .userLibraryMessages, op: nil,
             declaredCategoryRequired: nil,
             risk: .sensitive,
             rationale: "Reads Messages chat history."),
        Rule(id: "R006-photos",
             category: .userLibraryPhotos, op: nil,
             declaredCategoryRequired: .photoLibrary,
             risk: .sensitive,
             rationale: "Reads Photos library without declaring NSPhotoLibraryUsageDescription."),
        Rule(id: "R007-contacts",
             category: .userLibraryContacts, op: nil,
             declaredCategoryRequired: .contacts,
             risk: .sensitive,
             rationale: "Reads address book without declaring NSContactsUsageDescription."),
        Rule(id: "R008-calendar",
             category: .userLibraryCalendar, op: nil,
             declaredCategoryRequired: .calendar,
             risk: .sensitive,
             rationale: "Reads Calendar store without declaring NSCalendarsUsageDescription."),
        Rule(id: "R009-docs-write",
             category: .userDocuments, op: .write,
             declaredCategoryRequired: nil,
             risk: .expected,
             rationale: "Writes inside ~/Documents — typical for a document-based app."),
        Rule(id: "R010-removable",
             category: .removableVolume, op: nil,
             declaredCategoryRequired: nil,
             risk: .sensitive,
             rationale: "Touches a removable volume."),
        Rule(id: "R011-network-volume",
             category: .networkVolume, op: nil,
             declaredCategoryRequired: nil,
             risk: .sensitive,
             rationale: "Touches a network share."),
        Rule(id: "R012-tmp-write",
             category: .temporary, op: .write,
             declaredCategoryRequired: nil,
             risk: .expected,
             rationale: "Temp files in /tmp or DARWIN_USER_TEMP_DIR — normal."),
        Rule(id: "R013-system-write",
             category: .systemReadOnly, op: .write,
             declaredCategoryRequired: nil,
             risk: .surprising,
             rationale: "Tries to write into a system-read-only path."),
        Rule(id: "R014-bundle-internal",
             category: .bundleInternal, op: nil,
             declaredCategoryRequired: nil,
             risk: .expected,
             rationale: "Reads/writes inside its own app bundle.")
    ]
}
