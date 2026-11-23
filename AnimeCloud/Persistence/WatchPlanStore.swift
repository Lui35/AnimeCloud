import Foundation
import Combine
import Security

@MainActor
final class WatchPlanStore: ObservableObject {
    @Published private(set) var plans: [WatchPlan]
    private let defaults: UserDefaults
    private let storageKey = "watchPlans.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plans = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([WatchPlan].self, from: $0) } ?? []
    }

    func save(_ plan: WatchPlan) throws {
        var updated = plan
        if let previous = plans.first(where: { $0.id == plan.id }) {
            for index in updated.steps.indices {
                guard let old = previous.steps.first(where: { $0.id == updated.steps[index].id }) else { continue }
                updated.steps[index].completionOverride = updated.steps[index].completionOverride ?? old.completionOverride
                updated.steps[index].anime = updated.steps[index].anime ?? old.anime
            }
        }
        try persist([updated] + plans.filter { $0.id != plan.id })
    }

    func remove(_ id: String) throws { try persist(plans.filter { $0.id != id }) }

    func update(_ id: String, change: (inout WatchPlan) -> Void) throws {
        var updated = plans
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        change(&updated[index])
        try persist(updated)
    }

    func isComplete(_ step: WatchPlanStep, library: LibraryStore) -> Bool {
        step.completionOverride ?? step.anime.map { library.category(for: $0) == .watched } ?? false
    }

    func nextStep(in plan: WatchPlan, library: LibraryStore) -> WatchPlanStep? {
        plan.steps.first { (plan.includeOptional || !$0.isOptional) && !isComplete($0, library: library) }
    }

    private func persist(_ updated: [WatchPlan]) throws {
        guard let data = try? JSONEncoder().encode(updated) else { throw WatchOrderError.persistence }
        defaults.set(data, forKey: storageKey)
        plans = updated
    }
}

@MainActor
final class GeminiSettings: ObservableObject {
    @Published private(set) var isConfigured: Bool
    private static let service = "com.animecloud.reborn.gemini"
    private static let account = "personal-api-key"

    init() { isConfigured = Self.load() != nil }

    func apiKey() throws -> String {
        guard let key = Self.load(), !key.isEmpty else { throw WatchOrderError.missingKey }
        return key
    }

    func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw WatchOrderError.invalidKey }
        let query = Self.query
        let attributes = [kSecValueData: Data(key.utf8)] as CFDictionary
        let update = SecItemUpdate(query as CFDictionary, attributes)
        if update == errSecItemNotFound {
            var item = query
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecValueData] = Data(key.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw WatchOrderError.persistence }
        } else if update != errSecSuccess {
            throw WatchOrderError.persistence
        }
        isConfigured = true
    }

    func remove() throws {
        let status = SecItemDelete(Self.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WatchOrderError.persistence }
        isConfigured = false
    }

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func load() -> String? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
