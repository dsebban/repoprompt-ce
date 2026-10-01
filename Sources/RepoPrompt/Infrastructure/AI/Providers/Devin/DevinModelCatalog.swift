import Foundation

/// Devin reasoning effort expressed as effort-encoded model IDs (`gpt-6-sol-high`).
///
/// Devin ACP advertises one model ID per family plus a per-model `thought_level` option and
/// rejects effort-encoded IDs as `model` values, while the one-shot `devin -p --model` accepts
/// them and has no effort flag. One ID therefore names a model+effort on every surface; only
/// the ACP controller splits it into (advertised model, `thought_level` choice).
struct DevinModelCatalog {
    struct Thinking: Equatable {
        let configID: String
        let choiceRaw: String
    }

    struct Entry: Equatable {
        /// Selectable ID and full label (`GPT-6 Sol · High`).
        let option: AgentModelOption
        /// Model ID Devin ACP advertises for this family.
        let advertisedModelRaw: String
        /// Thinking choice to apply after selecting `advertisedModelRaw`; nil = model only.
        let thinking: Thinking?
    }

    /// Families whose sibling effort IDs are not Devin CLI model IDs (`devin models list`:
    /// Fusion IDs encode fixed per-model efforts; SWE-1.7's max variant is `swe-1-7-lightning`).
    /// They stay selectable as advertised, without synthesized siblings.
    private static let nonExpandingPrefixes = ["fusion-", "swe-1-"]

    let entries: [Entry]
    private let entriesByNormalizedRaw: [String: Entry]

    static var current: DevinModelCatalog {
        DevinModelCatalog(snapshot: AgentACPModelRegistry.shared.resolvedSnapshot(for: .devin))
    }

    init(snapshot: ACPDiscoveredSessionModels?) {
        let options = snapshot?.options ?? []
        let parameterSets = snapshot?.modelParameterSets ?? []
        let advertisedRaws = Set(options.map { Self.normalized($0.rawValue) })
        var entries: [Entry] = []
        var seen = Set<String>()

        for option in options {
            let expansion = Self.expansion(for: option, parameterSets: parameterSets)
            guard let expansion else {
                if seen.insert(Self.normalized(option.rawValue)).inserted {
                    entries.append(Entry(
                        option: option,
                        advertisedModelRaw: option.rawValue,
                        thinking: nil
                    ))
                }
                continue
            }
            for choice in expansion.definition.choices {
                let isAdvertised = choice.rawValue == expansion.encodedChoice.rawValue
                let raw = isAdvertised ? option.rawValue : "\(expansion.stem)-\(choice.rawValue)"
                let key = Self.normalized(raw)
                // An advertised ID always belongs to its own advertisement.
                guard isAdvertised || !advertisedRaws.contains(key), seen.insert(key).inserted else { continue }
                entries.append(Entry(
                    option: AgentModelOption(
                        rawValue: raw,
                        displayName: "\(expansion.familyDisplayName) · \(choice.displayName)",
                        description: option.description,
                        isPlaceholderDefault: false,
                        isProviderDefault: isAdvertised && option.isProviderDefault
                    ),
                    advertisedModelRaw: option.rawValue,
                    thinking: Thinking(configID: expansion.definition.configID, choiceRaw: choice.rawValue)
                ))
            }
        }
        self.entries = entries
        entriesByNormalizedRaw = Dictionary(entries.map { (Self.normalized($0.option.rawValue), $0) }) { first, _ in first }
    }

    func entry(matching raw: String) -> Entry? {
        entriesByNormalizedRaw[Self.normalized(raw)]
    }

    private struct Expansion {
        let stem: String
        let familyDisplayName: String
        let definition: ACPModelParameterDefinition
        let encodedChoice: ACPModelParameterChoice
    }

    private static func expansion(
        for option: AgentModelOption,
        parameterSets: [ACPModelParameterSet]
    ) -> Expansion? {
        let raw = option.rawValue
        let key = normalized(raw)
        guard !option.isPlaceholderDefault,
              !nonExpandingPrefixes.contains(where: { key.hasPrefix($0) })
        else { return nil }
        let matchingSets = parameterSets.filter { normalized($0.baseModelRaw) == key }
        guard matchingSets.count == 1,
              let definition = matchingSets[0].definition(kind: .thinking),
              definition.choices.allSatisfy({ $0.rawValue.range(of: "^[a-z]+$", options: .regularExpression) != nil })
        else { return nil }
        let encoded = definition.choices.filter { key.hasSuffix("-\($0.rawValue)") }
        guard encoded.count == 1 else { return nil }
        let encodedChoice = encoded[0]
        let stem = String(raw.dropLast(encodedChoice.rawValue.count + 1))
        return Expansion(
            stem: stem,
            familyDisplayName: familyDisplayName(option.displayName, encodedChoice: encodedChoice),
            definition: definition,
            encodedChoice: encodedChoice
        )
    }

    /// Strips a trailing encoded-effort label (optionally followed by "Thinking") so the family
    /// title never repeats the advertised effort.
    private static func familyDisplayName(_ displayName: String, encodedChoice: ACPModelParameterChoice) -> String {
        var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(" thinking") {
            name = String(name.dropLast(" thinking".count))
        }
        for label in [encodedChoice.displayName, encodedChoice.rawValue] {
            let suffix = " \(label)"
            if name.lowercased().hasSuffix(suffix.lowercased()) {
                return String(name.dropLast(suffix.count))
            }
        }
        return displayName
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
