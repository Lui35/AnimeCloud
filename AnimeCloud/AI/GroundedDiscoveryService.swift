import Foundation

struct DiscoveryAnswer: Identifiable, Sendable {
    let id = UUID()
    var headline: String
    var explanation: String
    var anime: [Anime]
    var source: String
}

protocol AnimeIntelligenceProviding: Sendable {
    func recommend(prompt: String, catalog: [Anime], favorites: [Anime]) async throws -> DiscoveryAnswer
}

/// A deterministic, private fallback. A Firebase/Gemini provider can conform to the
/// same protocol and return only IDs present in `catalog`.
struct GroundedDiscoveryService: AnimeIntelligenceProviding {
    func recommend(prompt: String, catalog: [Anime], favorites: [Anime]) async throws -> DiscoveryAnswer {
        let terms = tokens(prompt)
        guard !terms.isEmpty else {
            return DiscoveryAnswer(
                headline: "A few places to start",
                explanation: "Popular picks from the live Anime Cloud catalog.",
                anime: Array(catalog.prefix(8)),
                source: "Private catalog matching"
            )
        }

        let favoriteTerms = Set(favorites.flatMap { tokens([$0.name, $0.keywords ?? ""].joined(separator: " ")) })
        let ranked = catalog.map { item -> (Anime, Int) in
            let searchable = tokens([item.name, item.keywords ?? "", item.status ?? "", item.year ?? ""].joined(separator: " "))
            let direct = terms.reduce(0) { $0 + (searchable.contains($1) ? 12 : 0) }
            let affinity = favoriteTerms.reduce(0) { $0 + (searchable.contains($1) ? 1 : 0) }
            return (item, direct + min(affinity, 8))
        }
        let matches = ranked.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(10).map(\.0)
        return DiscoveryAnswer(
            headline: matches.isEmpty ? "Let’s widen the search" : "Made for this mood",
            explanation: matches.isEmpty
                ? "I couldn’t ground that request in the current catalog. Try a genre, year, or title fragment."
                : "These titles match your words and patterns in your favorites. Every result is verified against Anime Cloud.",
            anime: matches,
            source: "Private catalog matching • Gemini-ready"
        )
    }

    private func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }
}
